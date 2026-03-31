// ContactDetailPanel.swift
// aPhone Mirroring
//
// Right panel of the Calls tab. Contact-tinted gradient background, 90pt avatar with colored glow
// shadow, glass action buttons (Message/Call/Other in GlassEffectContainer), and a Liquid Glass
// segmented control switching between Details and Recent Calls sections.
//

import SwiftUI

// MARK: - ContactDetailPanel

struct ContactDetailPanel: View {
    let call: BridgeCall
    let allCalls: [BridgeCall]
    let bridge: DataBridgeClient
    @State private var detailTab = 0
    @State private var showMessageMenu = false
    @Namespace private var detailNS

    private var recentCalls: [BridgeCall] {
        allCalls.filter { $0.displayName == call.displayName }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Contact-tinted gradient — bleeds from top, fades to the panel base by midpoint
            LinearGradient(
                colors: [
                    Color(hue: call.hue, saturation: 0.45, brightness: 0.28),
                    Color(white: 0.17)
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── Avatar + name ─────────────────────────────────────────
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(hue: call.hue, saturation: 0.5, brightness: 0.72))
                            Text(call.initials)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 90, height: 90)
                        .shadow(
                            color: Color(hue: call.hue, saturation: 0.6, brightness: 0.5).opacity(0.5),
                            radius: 20, x: 0, y: 8
                        )

                        Text(call.displayName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                    // ── Action buttons — Message (SMS) · Call · More ──
                    GlassEffectContainer(spacing: 16) {
                        HStack(spacing: 16) {
                            smsActionButton
                            callActionButton
                            moreActionButton
                        }
                    }
                    .padding(.bottom, 26)

                    // ── Segmented control — Liquid Glass pills (interactive control) ──
                    GlassEffectContainer(spacing: 2) {
                        HStack(spacing: 2) {
                            detailTabItem(0, "Details")
                            detailTabItem(1, "Recent Calls")
                        }
                    }
                    .padding(.bottom, 16)

                    // ── Tab content ───────────────────────────────────────────
                    Group {
                        if detailTab == 0 {
                            detailsSection
                                .transition(.opacity)
                        } else {
                            recentCallsSection
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.22), value: detailTab)
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // SMS button — opens the in-app SMS conversation directly
    private var smsActionButton: some View {
        VStack(spacing: 7) {
            Button {
                NotificationCenter.default.post(
                    name: .navigateToSMS, object: nil, userInfo: ["phone": call.number]
                )
            } label: {
                Image(systemName: "message.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Text("Message")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // Call button — directly initiates the call
    private var callActionButton: some View {
        VStack(spacing: 7) {
            Button { bridge.placeCall(call.number) } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Text("Call")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // More button — shows all third-party app options (WhatsApp, Signal, etc.)
    private var moreActionButton: some View {
        VStack(spacing: 7) {
            Button {
                bridge.fetchContactApps(phone: call.number, name: call.displayName)
                showMessageMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .popover(isPresented: $showMessageMenu, arrowEdge: .bottom) {
                AppActionsMenu(phone: call.number, bridge: bridge,
                               onDismiss: { showMessageMenu = false })
            }
            Text("Other")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func detailTabItem(_ idx: Int, _ title: String) -> some View {
        let selected = detailTab == idx
        return Button {
            withAnimation(.smooth(duration: 0.25)) { detailTab = idx }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID(selected ? "detail-active" : "detail-\(idx)", in: detailNS)
    }

    private var detailsSection: some View {
        VStack(spacing: 0) {
            detailRow(icon: "phone", label: "Mobile", value: call.number)
            Divider().opacity(0.1).padding(.leading, 42)
            detailRow(icon: "clock", label: "Last call", value: call.timeLabel)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.20))
        )
    }

    private var recentCallsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentCalls.enumerated()), id: \.element.id) { idx, rec in
                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                recentCallRow(rec)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.20))
        )
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func recentCallRow(_ rec: BridgeCall) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rec.isOutgoing ? "phone.arrow.up.right"
                                             : "phone.arrow.down.left")
                .font(.system(size: 12))
                .foregroundStyle(rec.isMissed   ? .red
                                 : rec.isOutgoing ? Color.accentColor : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.isMissed ? "Missed" : rec.isOutgoing ? "Outgoing" : "Incoming")
                    .font(.system(size: 13))
                    .foregroundStyle(rec.isMissed ? .red : .primary)
                if let dur = rec.durationLabel {
                    Text(dur).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(rec.timeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
