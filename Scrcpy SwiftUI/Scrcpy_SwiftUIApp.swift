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
///   ┌─────────────────────────────────┐  ← toolbar (52 pt) — contains traffic lights + controls
///   ├─────────────────────────────────┤
///   │                                 │
///   │         phone content           │  ← SwiftUI content view (fixed)
///   │                                 │
///   └─────────────────────────────────┘
///
/// Collapsed: the window is exactly the phone viewport — no chrome, no dead space.
/// Expanded:  the window grows upward by 52 pt (origin.y stays fixed so the phone
///            never moves); the toolbar materialises above the phone.
/// Dragging:  only from the toolbar area (WindowDragArea), not the phone surface.
@Observable
final class WindowManager {
    private(set) weak var window: NSWindow?
    private(set) var barExpanded = false

    func register(_ w: NSWindow) {
        window = w

        // hiddenTitleBar + fullSizeContentView means the content fills the entire
        // window frame with no extra chrome. The transparent title bar overlaps
        // the topmost ~28 pt of our content but is invisible (no background, no
        // traffic lights). With isOpaque = false, macOS shadows the visible pixels
        // only, so the shadow hugs the phone shape.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .clear
        w.isOpaque = false

        // Phone surface must NOT move the window — only the toolbar drag area does.
        w.isMovableByWindowBackground = false

        // Traffic lights start invisible; revealed when the toolbar expands.
        setTrafficLightsAlpha(0, hidden: true)
    }

    /// Expand or collapse the toolbar.
    /// The window grows/shrinks upward (origin.y stays fixed = phone never moves).
    func setBarExpanded(_ expanded: Bool) {
        guard expanded != barExpanded, let w = window else { return }
        barExpanded = expanded

        if expanded {
            setTrafficLightsAlpha(0, hidden: false)
        }

        var newFrame = w.frame
        if expanded {
            newFrame.size.height += controlBarHeight   // grow up
        } else {
            newFrame.size.height -= controlBarHeight   // shrink up
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(newFrame, display: true)
            animateTrafficLights(alpha: expanded ? 1 : 0)
        }, completionHandler: {
            if !expanded { self.setTrafficLightsAlpha(0, hidden: true) }
        })
    }

    // MARK: - Traffic lights helpers

    private var trafficLightButtons: [NSButton] {
        guard let w = window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            w.standardWindowButton($0)
        }
    }

    private func setTrafficLightsAlpha(_ alpha: CGFloat, hidden: Bool) {
        trafficLightButtons.forEach {
            $0.alphaValue = alpha
            $0.isHidden = hidden
        }
    }

    private func animateTrafficLights(alpha: CGFloat) {
        trafficLightButtons.forEach {
            $0.animator().alphaValue = alpha
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
        // hiddenTitleBar applies fullSizeContentView so the content fills the
        // entire window frame — no dead space above the phone.
        .windowStyle(.hiddenTitleBar)
        // contentMinSize lets our manual setFrame calls work without fighting a
        // contentSize constraint, while still preventing the user from making the
        // window smaller than the phone.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 390, height: 844)
    }
}

// MARK: - WindowDragArea

/// An NSView that lets the toolbar row drag the window while leaving all
/// SwiftUI button interactions intact (buttons are in front in z-order).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
