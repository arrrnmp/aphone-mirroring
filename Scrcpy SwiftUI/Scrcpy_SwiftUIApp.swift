//
//  Scrcpy_SwiftUIApp.swift
//  Scrcpy SwiftUI
//

import SwiftUI
import AppKit

let controlBarHeight: CGFloat = 52

// MARK: - WindowManager

/// Manages the window reference and the expandable control-bar accessory.
///
/// Layout (top → bottom):
///   ┌─────────────────────────────────┐  ← native title bar (~28 pt)
///   │  ● ● ●   [device]   [buttons]  │  ← accessory VC (52 pt, expandable)
///   ├─────────────────────────────────┤
///   │                                 │
///   │         phone content           │  ← SwiftUI content view (fixed)
///   │                                 │
///   └─────────────────────────────────┘
///
/// When the accessory is hidden the window shrinks by 52 pt (upward), so the
/// phone content area never changes size — only the chrome above it grows/shrinks.
@Observable
final class WindowManager {
    private(set) weak var window: NSWindow?
    private(set) var barExpanded = false
    private(set) var accessoryVC: NSTitlebarAccessoryViewController?

    func register(_ w: NSWindow) {
        window = w

        // Hide the title text; keep traffic lights + native drag surface.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = false

        // Build the expandable accessory bar.
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom        // sits below title bar, above content
        vc.isHidden = true                  // collapsed at launch

        // Placeholder; ContentView replaces this with an NSHostingView.
        let placeholder = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: controlBarHeight))
        vc.view = placeholder

        w.addTitlebarAccessoryViewController(vc)
        accessoryVC = vc
    }

    /// Expand or collapse the control bar.
    /// AppKit resizes the window frame automatically (grows/shrinks upward).
    func setBarExpanded(_ expanded: Bool) {
        guard expanded != barExpanded, let vc = accessoryVC else { return }
        barExpanded = expanded
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            vc.animator().isHidden = !expanded
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            if let w = NSApp.windows.first {
                self.windowManager.register(w)
            }
        }
    }
}

// MARK: - App entry point

@main
struct Scrcpy_SwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(appDelegate.windowManager)
        }
        .windowStyle(.titleBar)             // real traffic lights + native drag
        .windowResizability(.contentSize)
        .defaultSize(width: 390, height: 844)
    }
}

// MARK: - AspectRatioConfigurator

/// Sets window.contentAspectRatio so the phone maintains its aspect ratio on resize.
struct AspectRatioConfigurator: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard size != .zero else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.contentAspectRatio = size
        }
    }
}

// MARK: - ControlBarAccessoryInstaller

/// Mounts a SwiftUI view into the window's titlebar accessory VC.
/// Placed as a zero-size `.background` in ContentView so it can reach the window.
struct ControlBarAccessoryInstaller<Content: View>: NSViewRepresentable {
    @Environment(WindowManager.self) private var windowManager
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let vc = windowManager.accessoryVC else { return }
        // Replace placeholder with a hosting view exactly once.
        if vc.view is NSHostingView<Content> { return }
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 0, height: controlBarHeight)
        vc.view = hosting
    }
}
