//
//  aPhone_MirroringApp.swift
//  aPhone Mirroring
//

import SwiftUI
import AppKit
import UserNotifications

let controlBarHeight: CGFloat = 46

// MARK: - WindowManager

/// Manages main-window chrome. The new split-panel layout makes this much simpler:
/// no floating control panel, no aspect-ratio locking, no bar expand/collapse.
/// Traffic lights are always visible (they live in the permanent phone-panel title bar).
@Observable
final class WindowManager {
    private(set) weak var window: NSWindow?
    private(set) var isPinned = false

    func register(_ w: NSWindow) {
        guard window !== w else { return }
        window = w

        // Transparent titlebar so the macOS compositor clips to the natural corner radius.
        w.titleVisibility           = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle    = .none
        w.backgroundColor           = .clear
        w.isOpaque                  = false
        w.contentView?.wantsLayer   = true
        w.contentView?.layer?.backgroundColor = CGColor.clear

        // Fullscreen disabled; content drives the window size.
        w.collectionBehavior = [.managed, .fullScreenNone]
        w.isMovableByWindowBackground = false
        w.level = isPinned ? .floating : .normal

        // Traffic lights are always visible in the split layout.
        setTrafficLightsAlpha(1, hidden: false)
    }

    func toggleAlwaysOnTop() {
        guard let w = window else { return }
        isPinned.toggle()
        w.level = isPinned ? .floating : .normal
    }

    // MARK: Traffic lights

    private var trafficLightButtons: [NSButton] {
        guard let w = window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            w.standardWindowButton($0)
        }
    }

    private func setTrafficLightsAlpha(_ alpha: CGFloat, hidden: Bool) {
        trafficLightButtons.forEach { $0.alphaValue = alpha; $0.isHidden = hidden }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let windowManager = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register the base "no actions" category that all info notifications use
        let infoCategory = UNNotificationCategory(
            identifier: "android_info", actions: [], intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([infoCategory])
    }

    // Show notification banners AND add to notification center list when app is foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Handle the user tapping a notification action (Reply button, action buttons, etc.)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }

        let actionId = response.actionIdentifier
        guard actionId != UNNotificationDefaultActionIdentifier,
              actionId != UNNotificationDismissActionIdentifier else { return }

        let userInfo = response.notification.request.content.userInfo
        guard let notifKey = userInfo["notifKey"] as? String else { return }

        // Action identifiers are "ACTION_0", "ACTION_1", etc.
        guard let indexStr = actionId.components(separatedBy: "_").last,
              let actionIndex = Int(indexStr) else { return }

        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            DataBridgeClient.shared?.sendNotificationAction(
                notifKey: notifKey,
                actionIndex: actionIndex,
                replyText: replyText
            )
        }
    }
}

// MARK: - App entry point

@main
struct aPhone_MirroringApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(appDelegate.windowManager)
                .task {
                    let center = UNUserNotificationCenter.current()
                    let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                    log("Notification permission: \(granted ? "granted ✓" : "denied — enable in System Settings > Notifications")",
                        level: granted ? .ok : .warn)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 760)
    }
}

// MARK: - WindowConfigurator

/// Zero-size background view that fires `WindowManager.register` whenever
/// this view moves to a window — covers initial launch and close-then-reopen.
struct WindowConfigurator: NSViewRepresentable {
    let windowManager: WindowManager

    func makeNSView(context: Context) -> ConfigNSView { ConfigNSView(windowManager: windowManager) }
    func updateNSView(_ nsView: ConfigNSView, context: Context) {}

    final class ConfigNSView: NSView {
        let windowManager: WindowManager
        init(windowManager: WindowManager) {
            self.windowManager = windowManager
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { windowManager.register(w) }
        }
    }
}

// MARK: - WindowDragArea

/// NSView that makes the title-bar row drag the window while leaving SwiftUI
/// button interactions intact (buttons sit in front in z-order).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
