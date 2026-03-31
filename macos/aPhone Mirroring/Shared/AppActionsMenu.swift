// AppActionsMenu.swift
// aPhone Mirroring
//
// Popover content for the "Other" action button in ContactDetailPanel and ContactInfoPanel. Lists
// third-party app actions (Signal, WhatsApp, Telegram, etc.) from bridge.contactApps, launched
// via bridge.executeContactAction(uri:).
//

import SwiftUI
import AppKit

// MARK: - AppActionsMenu

/// Popover for the "Other" button — shows only dynamically-detected third-party app actions.
struct AppActionsMenu: View {
    let phone: String
    let bridge: DataBridgeClient
    let onDismiss: () -> Void

    private var apps: [BridgeContactApp]? { bridge.contactApps[phone] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let apps {
                if apps.isEmpty {
                    Text("No connected apps found")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                } else {
                    ForEach(apps, id: \.packageName) { app in
                        Button {
                            onDismiss()
                            // Try to open on Mac first (WhatsApp / Telegram); fall back to first Android action
                            if !openOnMac(packageName: app.packageName, phone: phone) {
                                if let first = app.actions.first {
                                    bridge.executeContactAction(dataId: first.dataId,
                                                                mimeType: first.mimeType)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if let img = app.iconImage {
                                    Image(nsImage: img)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                }
                                Text(app.appName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
    }

    /// Try to open a known app on the Mac using its URL scheme (chat / profile only).
    /// Returns true if a Mac app handled the URL.
    @discardableResult
    private func openOnMac(packageName: String, phone: String) -> Bool {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        let urlString: String?
        switch packageName {
        case "com.whatsapp", "com.whatsapp.w4b":
            urlString = "whatsapp://send?phone=\(digits)"
        case "org.telegram.messenger", "org.telegram.messenger.web", "org.telegram.plus":
            urlString = "tg://resolve?phone=\(digits)"
        default:
            urlString = nil
        }
        guard let str = urlString, let url = URL(string: str) else { return false }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
