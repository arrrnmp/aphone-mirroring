// PopoutCoordinator.swift
// aPhone Mirroring
//
// NSWindowDelegate + ObservableObject for the pop-out phone window.
// Stays ObservableObject (not @Observable) because it subclasses NSObject for delegation.
//
// Responsibilities:
//   • Reposition the ControlPanel sidebar on popout move/resize events
//   • Track fullscreen state and animate sidebar in/out on enter/exit
//   • Manage the idle-fade timer (4 s → alpha 0.35) for the sidebar
//   • Publish isPinned (window level .floating / .normal) and isFullscreen
//   • On windowDidBecomeKey / windowDidResignKey: show / hide sidebar
//

import AppKit
import Combine

/// Manages the floating hardware-control sidebar window relative to the popout phone window.
/// Also detects fullscreen transitions so PopoutView can show/hide the embedded bottom controls.
final class PopoutCoordinator: NSObject, NSWindowDelegate, ObservableObject {

    @Published private(set) var isFullscreen: Bool = false
    @Published private(set) var isPinned: Bool = false

    /// Kept in sync by PhonePanelView so the exit-fullscreen snap uses the true video ratio.
    var videoRatio: CGFloat = 9.0 / 16.0
    /// Height of the window just before entering fullscreen.
    private var preFSHeight: CGFloat = 640

    private(set) weak var sidebarWindow: NSWindow?
    private weak var popoutWindow: NSWindow?
    private var idleTimer:   Timer?
    private var settleTimer: Timer?
    private var isDragging = false
    private var eventMonitor: Any?

    func togglePin() {
        guard let w = popoutWindow else { return }
        isPinned.toggle()
        w.level = isPinned ? .floating : .normal
    }

    func setup(popout: NSWindow, sidebar: NSWindow) {
        popoutWindow  = popout
        sidebarWindow = sidebar
        popout.delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillMove(_:)),
            name: NSWindow.willMoveNotification, object: popout
        )
        // Reposition sidebar when the popout resizes (e.g. device rotation).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidResize(_:)),
            name: NSWindow.didResizeNotification, object: popout
        )

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window === self?.sidebarWindow { self?.resetIdleTimer() }
            return event
        }

        resetIdleTimer()
    }

    func sidebarDidInteract() { resetIdleTimer() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        idleTimer?.invalidate()
        settleTimer?.invalidate()
    }

    // MARK: NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Save the pre-fullscreen height so we can restore to it exactly on exit.
        if let popout = notification.object as? NSWindow {
            preFSHeight = popout.frame.height
        }
        isFullscreen = true
        // Hide the sidebar — controls move inside the window as a bottom bar.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            sidebarWindow?.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sidebarWindow?.orderOut(nil)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        guard let popout = notification.object as? NSWindow else { return }

        // Snap window to the saved pre-fullscreen height × current video ratio.
        // We deliberately ignore contentAspectRatio here — it may have been corrupted
        // by the onToolbarExpand callback reading screen-sized dimensions during fullscreen.
        let targetH = preFSHeight
        let targetW = (targetH * videoRatio).rounded()
        var f = popout.frame
        let dx = ((f.size.width - targetW) / 2).rounded()
        f.size.width  = targetW
        f.size.height = targetH
        f.origin.x   += dx
        popout.setFrame(f, display: true, animate: false)
        // Re-lock the aspect ratio to the phone's current ratio (no toolbar offset —
        // the toolbar auto-hides, so the window's natural ratio is the phone's ratio).
        popout.contentAspectRatio = NSSize(width: videoRatio, height: 1)

        // Restore the sidebar next to the (now-windowed) popout.
        sidebarWindow?.alphaValue = 0
        sidebarWindow?.orderFront(nil)
        repositionSidebar(relativeTo: popout)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            sidebarWindow?.animator().alphaValue = 1.0
        }
        resetIdleTimer()
    }

    func windowDidMove(_ notification: Notification) {
        guard let popout = notification.object as? NSWindow else { return }
        repositionSidebar(relativeTo: popout)
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self, self.isDragging else { return }
            self.isDragging = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.sidebarWindow?.animator().alphaValue = 1.0
            }
            self.resetIdleTimer()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        sidebarWindow?.orderOut(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        sidebarWindow?.orderFront(nil)
        resetIdleTimer()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isFullscreen else { return }
        sidebarWindow?.orderFront(nil)
        resetIdleTimer()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isFullscreen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if NSApp.keyWindow !== self.sidebarWindow {
                self.sidebarWindow?.orderOut(nil)
            }
        }
    }

    // MARK: Resize / drag detection

    @objc private func handleDidResize(_ notification: Notification) {
        guard !isFullscreen, let popout = notification.object as? NSWindow else { return }
        repositionSidebar(relativeTo: popout)
    }

    @objc private func handleWillMove(_ notification: Notification) {
        isDragging = true
        idleTimer?.invalidate()
        settleTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            sidebarWindow?.animator().alphaValue = 0
        }
    }

    // MARK: Helpers

    private func repositionSidebar(relativeTo popout: NSWindow) {
        guard let sWin = sidebarWindow else { return }
        let pf  = popout.frame
        let sv  = (popout.screen ?? NSScreen.main!).visibleFrame
        let sW  = sWin.frame.width
        let sH  = sWin.frame.height
        var x   = pf.maxX + 12
        if x + sW > sv.maxX { x = pf.minX - sW - 12 }
        let y   = max(sv.minY, min(sv.maxY - sH, pf.midY - sH / 2))
        sWin.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        guard let sw = sidebarWindow else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            sw.animator().alphaValue = 1.0
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self.sidebarWindow?.animator().alphaValue = 0.35
            }
        }
    }
}
