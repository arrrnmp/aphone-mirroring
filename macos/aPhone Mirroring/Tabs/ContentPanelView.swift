// ContentPanelView.swift
// aPhone Mirroring
//
// Right split-panel: Liquid Glass pill tab bar (Messages / Photos / Contacts / Calls),
// Bluetooth pairing banner, auth overlay (LockedView), and the active tab's content.
// Shares a single sidebarWidth state across all tabs so panel width persists on tab switch.
// Also owns the floating call window lifecycle (CallWindowController.shared).
//

import SwiftUI
import AppKit

// MARK: - PhoneTab

enum PhoneTab: CaseIterable {
    case messages, photos, contacts, calls

    var title: String {
        switch self {
        case .messages: "Messages"
        case .photos:   "Photos"
        case .contacts: "Contacts"
        case .calls:    "Calls"
        }
    }
}

// MARK: - LockedView

struct LockedView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular, in: .circle)

                VStack(spacing: 8) {
                    Text("Verification Required")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Your phone data is protected.\nVerify to view messages, photos, and calls.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 280)
                }

                Button {
                    Task { await auth.authenticate() }
                } label: {
                    Label(auth.unlockLabel, systemImage: auth.unlockIcon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 180)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .disabled(auth.isAuthenticating)
                .overlay {
                    if auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - ContentPanelView

struct ContentPanelView: View {

    let bridge: DataBridgeClient
    let btManager: BluetoothPairingManager
    @Environment(AuthManager.self) private var auth
    @State private var selectedTab: PhoneTab = .messages
    @State private var sidebarWidth: CGFloat = 232
    @State private var navigateSMSPhone: String? = nil
    @Namespace private var tabNS

    private static let bg = Color(white: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — single glass surface with sliding selection indicator.
            topTabBar
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Bluetooth pairing banner — shown until paired
            btPairingBanner

            ZStack {
                if !auth.isLocked {
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .simultaneousGesture(TapGesture().onEnded { auth.userDidInteract() })
                }
                if auth.isLocked {
                    LockedView().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: auth.isLocked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.bg.ignoresSafeArea())
        // Switch to Messages tab and thread when a "navigate to SMS" action fires
        .task {
            for await notif in NotificationCenter.default.notifications(named: .navigateToSMS) {
                let phone = notif.userInfo?["phone"] as? String
                withAnimation(.smooth(duration: 0.28)) { selectedTab = .messages }
                navigateSMSPhone = phone
            }
        }
        // Show / dismiss the floating call window when an active call starts or ends
        .onChange(of: bridge.activeCall) { _, call in
            if let call {
                CallWindowController.shared.show(call: call, bridge: bridge)
            } else {
                CallWindowController.shared.dismiss()
            }
        }
    }

    // MARK: - Top tab bar

    // One glass surface for the whole bar; a matchedGeometryEffect capsule slides
    // between items to indicate selection — no per-item glass.
    private var topTabBar: some View {
        HStack(spacing: 0) {
            ForEach(PhoneTab.allCases, id: \.self) { tab in
                tabBarItem(tab)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }

    private func tabBarItem(_ tab: PhoneTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            if auth.isLocked {
                Task { await auth.authenticate() }
            } else {
                withAnimation(.smooth(duration: 0.28)) { selectedTab = tab }
                auth.userDidInteract()
            }
        } label: {
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .matchedGeometryEffect(id: "tab-selection", in: tabNS)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.28), value: selected)
    }

    // MARK: - Bluetooth pairing banner

    @ViewBuilder
    private var btPairingBanner: some View {
        switch btManager.status {
        case .checking:
            btBannerShell {
                ProgressView().controlSize(.mini).tint(.secondary)
                Text("Checking Bluetooth pairing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .notPaired(let name):
            btBannerShell {
                Image(systemName: "bluetooth")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair \(name) via Bluetooth")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Required for routing call audio to your Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await btManager.startPairing() }
                } label: {
                    Text("Pair Now")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

        case .pairing(let name):
            btBannerShell {
                ProgressView().controlSize(.mini).tint(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pairing with \(name)…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Accept the pairing request on your phone")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

        case .unavailable(let msg):
            btBannerShell {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    btManager.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .idle, .paired:
            EmptyView()
        }
    }

    private func btBannerShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.18).clipShape(RoundedRectangle(cornerRadius: 10)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.smooth(duration: 0.3), value: btManager.status == .paired)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .messages: MessagesTabView(listWidth: $sidebarWidth, bridge: bridge, navigateSMSPhone: $navigateSMSPhone)
        case .photos:   PhotosTabView(bridge: bridge)
        case .calls:    CallsTabView(listWidth: $sidebarWidth, bridge: bridge)
        case .contacts: ContactsTabView(listWidth: $sidebarWidth, bridge: bridge)
        }
    }
}
