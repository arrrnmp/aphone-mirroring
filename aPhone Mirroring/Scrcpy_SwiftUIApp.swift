//
//  aPhone_MirroringApp.swift
//  Scrcpy SwiftUI
//

import SwiftUI
import AppKit

let controlBarHeight: CGFloat = 52

// MARK: - WindowManager

/// Manages the main window and the floating control-panel side window.
///
/// Main window layout when expanded (top → bottom):
///   ┌─────────────────────────────────┐  ← toolbar (52 pt) — traffic lights + controls
///   ├─────────────────────────────────┤
///   │                                 │
///   │         phone content           │
///   │                                 │
///   └─────────────────────────────────┘
///
/// Collapsed: window = phone viewport only. Expanded: window grows upward by 52 pt.
/// Control panel: borderless floating window that tracks the main window's position
/// and snaps to whichever side has more screen space.
@Observable
final class WindowManager {
    private(set) weak var window: NSWindow?
    private(set) var barExpanded = false
    private(set) var isPinned = false

    private var phoneWidth: Int = 390
    private var phoneHeight: Int = 844

    // MARK: - Control panel — stored state
    private var controlPanel: NSWindow?
    private var panelVisible   = false   // true = we *want* the panel on screen
    private var isDragging     = false
    private var dragDebounce:  DispatchWorkItem?
    private var idleTimer:     DispatchWorkItem?
    private var eventMonitor:  Any?
    // NotificationCenter observers
    private var obsMove:    Any?
    private var obsResize:  Any?
    private var obsClose:   Any?
    private var obsWillMove: Any?
    private var obsResign:  Any?
    private var obsActive:  Any?
    private var obsMini:    Any?
    private var obsDemini:  Any?

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

        // Restore always-on-top level in case window was recreated.
        w.level = isPinned ? .floating : .normal

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

    // MARK: - Control panel — public API

    func showControlPanel(controlSocket: ScrcpyControlSocket) {
        if controlPanel == nil { buildControlPanel(controlSocket: controlSocket) }
        panelVisible = true
        controlPanel?.level = isPinned ? .floating : .normal
        updateControlPanelPosition()
        controlPanel?.contentView?.alphaValue = 0
        controlPanel?.orderFront(nil)
        animatePanel(to: 1)
        scheduleIdleDim()
    }

    func hideControlPanel() {
        panelVisible = false
        idleTimer?.cancel()
        animatePanel(to: 0) { [weak self] in self?.controlPanel?.orderOut(nil) }
    }

    // MARK: - Control panel — construction

    private func buildControlPanel(controlSocket: ScrcpyControlSocket) {
        let hosting = NSHostingView(rootView: ControlPanelView(controlSocket: controlSocket))
        hosting.sizingOptions = .preferredContentSize

        let panel = NSWindow(contentRect: .zero, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        controlPanel = panel

        let nc = NotificationCenter.default

        // Drag start: fade panel out (teleport illusion)
        obsWillMove = nc.addObserver(
            forName: NSWindow.willMoveNotification, object: window, queue: .main
        ) { [weak self] _ in self?.onDragStart() }

        // Each move event during drag: debounce to detect when drag ends
        obsMove = nc.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in self?.onMainWindowMoved() }

        // Resize (e.g. rotation): just reposition silently
        obsResize = nc.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updateControlPanelPosition() }

        // Main window closes → close panel too
        obsClose = nc.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.onMainWindowClose() }

        // App loses focus → fade panel out
        obsResign = nc.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.panelVisible == true else { return }
            self?.animatePanel(to: 0)
        }

        // App regains focus → fade panel back in
        obsActive = nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.panelVisible == true else { return }
            self?.animatePanel(to: 1)
            self?.scheduleIdleDim()
        }

        // Main window minimized → hide panel (it would otherwise float orphaned over the desktop)
        obsMini = nc.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.controlPanel?.orderOut(nil)
        }

        // Main window restored from dock → bring panel back if it should be visible
        obsDemini = nc.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, self.panelVisible else { return }
            self.updateControlPanelPosition()
            self.controlPanel?.contentView?.alphaValue = 0
            self.controlPanel?.orderFront(nil)
            self.animatePanel(to: 1)
            self.scheduleIdleDim()
        }

        // Mouse activity on the panel: undim and reset idle timer
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.window === self?.controlPanel { self?.onPanelInteraction() }
            return event
        }
    }

    // MARK: - Control panel — drag teleport

    private func onDragStart() {
        guard panelVisible else { return }
        isDragging = true
        animatePanel(to: 0)
        // Safety: if no didMove ever fires (click without drag), recover after 0.5 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isDragging else { return }
            self.isDragging = false
            if self.panelVisible { self.animatePanel(to: 1); self.scheduleIdleDim() }
        }
    }

    private func onMainWindowMoved() {
        guard isDragging else {
            updateControlPanelPosition()   // programmatic move — just reposition
            return
        }
        // Drag in progress — debounce: fire 0.15 s after the last move event
        dragDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isDragging = false
            if self.panelVisible {
                self.updateControlPanelPosition()
                self.animatePanel(to: 1)
                self.scheduleIdleDim()
            }
        }
        dragDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func onMainWindowClose() {
        idleTimer?.cancel()
        dragDebounce?.cancel()
        controlPanel?.close()
        controlPanel = nil
        let nc = NotificationCenter.default
        [obsMove, obsResize, obsClose, obsWillMove, obsResign, obsActive, obsMini, obsDemini].forEach {
            if let o = $0 { nc.removeObserver(o) }
        }
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    // MARK: - Control panel — idle dimming

    private func onPanelInteraction() {
        guard panelVisible else { return }
        if let p = controlPanel, (p.contentView?.alphaValue ?? 0) < 0.95 { animatePanel(to: 1) }
        scheduleIdleDim()
    }

    private func scheduleIdleDim() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panelVisible else { return }
            self.animatePanel(to: 0.35)
        }
        idleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: - Control panel — animation & positioning

    private func animatePanel(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        guard let panel = controlPanel else { completion?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.contentView?.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func updateControlPanelPosition() {
        guard let main = window, let panel = controlPanel else { return }
        let screen = main.screen ?? NSScreen.main
        guard let screen else { return }

        let mainFrame = main.frame
        let panelSize = panel.frame.size
        let visible   = screen.visibleFrame
        let gap: CGFloat = 12

        // More room on the right → right side, else left
        let x: CGFloat = (visible.maxX - mainFrame.maxX) >= (mainFrame.minX - visible.minX)
            ? mainFrame.maxX + gap
            : mainFrame.minX - panelSize.width - gap

        let y  = (mainFrame.midY - panelSize.height / 2)
            .clamped(to: visible.minY ... max(visible.minY, visible.maxY - panelSize.height))
        let cx = x.clamped(to: visible.minX ... max(visible.minX, visible.maxX - panelSize.width))

        panel.setFrameOrigin(NSPoint(x: cx, y: y))
    }

    // MARK: - Always on top

    func toggleAlwaysOnTop() {
        guard let w = window else { return }
        isPinned.toggle()
        w.level = isPinned ? .floating : .normal
        controlPanel?.level = w.level
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
struct aPhone_MirroringApp: App {
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
