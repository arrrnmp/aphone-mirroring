// ContentView.swift
// aPhone Mirroring
//
// Root split-panel layout:
//   Left  — Phone panel: Liquid Glass background, phone viewport, controls tab bar.
//   Right — Content panel: pill tab bar (Messages / Photos / Calls / Contacts), auth overlay.
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Navigation notifications

extension NSNotification.Name {
    /// Post to navigate the Messages tab to a specific phone number's thread.
    static let navigateToSMS = NSNotification.Name("aphone.navigateToSMS")
}

// MARK: - ContentView (root)

struct ContentView: View {

    @State private var manager = ScrcpyManager()
    @State private var appLog = AppLog.shared
    @State       private var auth     = AuthManager()
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        HStack(spacing: 0) {
            // ── Left: Phone panel ─────────────────────────────────────────────
            PhonePanelView(manager: manager, appLog: appLog)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)

            // ── Right: Content panel ──────────────────────────────────────────
            ContentPanelView(bridge: manager.dataBridge, btManager: manager.btManager)
                .frame(maxWidth: .infinity)
                .environment(auth)
        }
        .ignoresSafeArea(edges: .all)
        .background(Color.clear)
        .background(WindowConfigurator(windowManager: windowManager))
        .preferredColorScheme(.dark)
        .task { await manager.refreshDevices() }
        .onChange(of: manager.videoStream.videoSize) { _, size in
            manager.controlSocket.updateVideoSize(
                width:  Int(size.width),
                height: Int(size.height)
            )
        }
        // Auth lifecycle — resign covers screen lock & fast-user-switch too
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                auth.handleAppResigned()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                auth.handleAppActivated()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .frame(width: 900, height: 760)
}
