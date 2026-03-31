// WindowChromeViews.swift
// aPhone Mirroring
//
// NSViewRepresentable bridges for window chrome: ToolbarHoverArea (tracking area over the top 50pt
// of the popout, fires toolbarVisible changes), TrafficLightController (syncs traffic-light button
// alphaValue with toolbarVisible), and WindowDragArea / WindowConfigurator
// (in Scrcpy_SwiftUIApp.swift — not here).
//

import SwiftUI
import AppKit

// MARK: - ToolbarHoverArea

/// Transparent NSViewRepresentable that tracks when the mouse enters/exits the top
/// `topHeight` points of the hosting window. Passes clicks through via hitTest → nil.
struct ToolbarHoverArea: NSViewRepresentable {
    let topHeight: CGFloat
    let onEnter:   () -> Void
    let onExit:    () -> Void

    func makeNSView(context: Context) -> HoverNSView {
        HoverNSView(topHeight: topHeight, onEnter: onEnter, onExit: onExit)
    }
    func updateNSView(_ nsView: HoverNSView, context: Context) {}

    final class HoverNSView: NSView {
        let topHeight: CGFloat
        let onEnter:   () -> Void
        let onExit:    () -> Void
        private var trackingArea: NSTrackingArea?

        init(topHeight: CGFloat, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
            self.topHeight = topHeight
            self.onEnter   = onEnter
            self.onExit    = onExit
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let ta = trackingArea { removeTrackingArea(ta) }
            // NSView y-axis: 0 at bottom, bounds.height at top.
            let rect = NSRect(x: 0, y: bounds.height - topHeight,
                              width: bounds.width, height: topHeight)
            let ta = NSTrackingArea(rect: rect,
                                    options: [.mouseEnteredAndExited, .activeAlways],
                                    owner: self, userInfo: nil)
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func mouseEntered(with event: NSEvent) { onEnter() }
        override func mouseExited(with event: NSEvent)  { onExit()  }
        // Transparent to clicks — video / buttons underneath remain interactive.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - TrafficLightController

/// Zero-size NSViewRepresentable that animates the hosting window's traffic-light
/// buttons in/out in sync with the popout toolbar's hover-reveal state.
struct TrafficLightController: NSViewRepresentable {
    let show: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        let alpha: CGFloat = show ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.standardWindowButton(.closeButton)?.animator().alphaValue   = alpha
            window.standardWindowButton(.miniaturizeButton)?.animator().alphaValue = alpha
            window.standardWindowButton(.zoomButton)?.animator().alphaValue    = alpha
        }
    }
}
