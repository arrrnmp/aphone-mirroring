//
//  Scrcpy_SwiftUIApp.swift
//  Scrcpy SwiftUI
//

import SwiftUI
import AppKit

let controlBarHeight: CGFloat = 52

// MARK: - WindowManager

/// Manages the window reference and the collapsible toolbar.
///
/// Layout when expanded (top → bottom):
///   ┌─────────────────────────────────┐  ← toolbar (52 pt) — traffic lights + controls
///   ├─────────────────────────────────┤
///   │                                 │
///   │         phone content           │
///   │                                 │
///   └─────────────────────────────────┘
///
/// Collapsed: window = phone viewport only. Expanded: window grows upward by 52 pt.
@Observable
final class WindowManager {
    private(set) weak var window: NSWindow?
    private(set) var barExpanded = false

    private var phoneWidth: Int = 390
    private var phoneHeight: Int = 844

    func register(_ w: NSWindow) {
        guard window !== w else { return }
        window = w

        // Keep .titled so native traffic lights, drag, and resize all work.
        // transparent + isOpaque=false means the macOS compositor clips the window
        // to its natural corner radius — the phone content fills that shape.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = .clear
        w.isOpaque = false

        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = CGColor.clear

        // Disable fullscreen; zoom button just resizes to content.
        w.collectionBehavior = [.managed, .fullScreenNone]

        // Lock to default portrait phone ratio until a device connects.
        applyAspectRatioConstraint(to: w)

        // Only the toolbar drag area moves the window, not the phone surface.
        w.isMovableByWindowBackground = false

        // Traffic lights start hidden; revealed when toolbar expands.
        setTrafficLightsAlpha(0, hidden: true)
    }

    /// Expand or collapse the toolbar.
    /// origin.y stays fixed so the phone never moves; the window grows upward.
    func setBarExpanded(_ expanded: Bool) {
        guard expanded != barExpanded, let w = window else { return }
        barExpanded = expanded

        // Keep aspect ratio constraint in sync with toolbar presence.
        applyAspectRatioConstraint(to: w)

        if expanded { setTrafficLightsAlpha(0, hidden: false) }

        var newFrame = w.frame
        newFrame.size.height += expanded ? controlBarHeight : -controlBarHeight

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(newFrame, display: true)
            animateTrafficLights(alpha: expanded ? 1 : 0)
        }, completionHandler: {
            if !expanded { self.setTrafficLightsAlpha(0, hidden: true) }
        })
    }

    // MARK: - Aspect ratio

    /// Called when the device's real video resolution arrives.
    /// Locks resize to the phone's aspect ratio and animates the window height
    /// to match at the current width.
    func setAspectRatio(width: Int, height: Int) {
        guard let w = window, width > 0, height > 0 else { return }

        let orientationFlipped = (phoneWidth > phoneHeight) != (width > height)
        phoneWidth = width
        phoneHeight = height
        applyAspectRatioConstraint(to: w)

        // When the orientation flips (portrait ↔ landscape), use the current phone
        // height as the new width so the viewport stays roughly the same size.
        // Otherwise just refit the height to the current width as before.
        let currentPhoneH = w.frame.height - (barExpanded ? controlBarHeight : 0)
        let targetPhoneW: CGFloat = orientationFlipped ? currentPhoneH : w.frame.width
        let targetPhoneH = (targetPhoneW * CGFloat(height) / CGFloat(width)).rounded()
        let targetWindowW = targetPhoneW
        let targetWindowH = targetPhoneH + (barExpanded ? controlBarHeight : 0)

        guard abs(targetWindowH - w.frame.height) > 2 || abs(targetWindowW - w.frame.width) > 2 else { return }

        var newFrame = w.frame
        let deltaH = targetWindowH - w.frame.height
        let deltaW = targetWindowW - w.frame.width
        newFrame.size.width  = targetWindowW
        newFrame.size.height = targetWindowH
        newFrame.origin.y -= deltaH          // grow upward, phone bottom stays put
        newFrame.origin.x -= (deltaW / 2)   // keep window horizontally centered

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(newFrame, display: true)
        }
    }

    /// Applies `contentAspectRatio` so that user-resize always keeps the
    /// phone viewport at the phone's native aspect ratio.
    private func applyAspectRatioConstraint(to w: NSWindow) {
        // Include toolbar height when expanded so the phone area (not the whole
        // window) maintains the correct ratio during user drag-resize.
        let totalH = phoneHeight + (barExpanded ? Int(controlBarHeight) : 0)
        w.contentAspectRatio = NSSize(width: phoneWidth, height: totalH)
    }

    // MARK: - Traffic lights

    private var trafficLightButtons: [NSButton] {
        guard let w = window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            w.standardWindowButton($0)
        }
    }

    private func setTrafficLightsAlpha(_ alpha: CGFloat, hidden: Bool) {
        trafficLightButtons.forEach { $0.alphaValue = alpha; $0.isHidden = hidden }
    }

    private func animateTrafficLights(alpha: CGFloat) {
        trafficLightButtons.forEach { $0.animator().alphaValue = alpha }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    // Window registration is handled by WindowConfigurator in ContentView,
    // which fires viewDidMoveToWindow on every window placement (including reopen).
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 390, height: 844)
    }
}

// MARK: - WindowConfigurator

/// Zero-size background view that calls WindowManager.register whenever this
/// view moves to a window — covers initial launch and close-then-reopen via Dock.
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

/// NSView that makes the toolbar row drag the window while leaving SwiftUI
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
