// PhonePanelView.swift
// aPhone Mirroring
//
// Left split-panel: phone viewport (video or state cards), glass title bar,
// hardware controls row, and log panel overlay. Owns the pop-out flow —
// creates the floating NSWindow + ControlPanel sidebar via makePopoutWindow /
// makeControlSidebarWindow and delegates window lifecycle to PopoutCoordinator.
//

import SwiftUI
import AppKit

// MARK: - PhonePanelView

struct PhonePanelView: View {

    let manager: ScrcpyManager
    let appLog: AppLog
    @Environment(WindowManager.self) private var windowManager
    @State private var showLogPanel     = false
    @State private var popoutWindow:    NSWindow? = nil
    @State private var sidebarWindow:   NSWindow? = nil
    @State private var viewportIsPopped = false
    @State private var coordinator:     PopoutCoordinator? = nil
    @Namespace private var titleBarNS

    var body: some View {
        VStack(spacing: 0) {
            // Title bar row
            phoneTitleBar

            Divider().opacity(0.12)

            // Phone viewport fills remaining space
            phoneViewport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if !viewportIsPopped, let flash = manager.screenshotFlash {
                        ScreenshotFlashView(image: flash.image, url: flash.url)
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                            .id(flash.id)
                    }
                }

            // Controls tab bar — only when connected and not popped out
            if manager.state == .connected, !viewportIsPopped {
                Divider().opacity(0.12)
                controlsSection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: manager.state == .connected)
        .animation(.easeInOut(duration: 0.22), value: viewportIsPopped)
        // Log panel slides up from bottom of the phone panel
        .overlay(alignment: .bottom) {
            if showLogPanel {
                LogPanelView(appLog: appLog) { showLogPanel = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLogPanel)
        .background(.thinMaterial)
        // Close popout when disconnected
        .onChange(of: manager.state == .connected) { _, isConnected in
            if !isConnected { retreatViewport() }
        }
        // Sync state when the user closes either floating window directly
        .task {
            for await notif in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                let win = notif.object as? NSWindow
                if win === popoutWindow || win === sidebarWindow { retreatViewport() }
            }
        }
        // Keep the popout window in sync when the device rotates.
        .onChange(of: manager.videoStream.videoSize) { oldSize, newSize in
            guard viewportIsPopped, let win = popoutWindow, newSize.width > 0 else { return }
            let newRatio = newSize.width / newSize.height
            // Keep coordinator in sync so exit-fullscreen snaps to the current ratio.
            coordinator?.videoRatio = newRatio
            let orientationFlipped = oldSize.width > 0 &&
                (oldSize.width > oldSize.height) != (newSize.width > newSize.height)
            if orientationFlipped {
                // Use the current phone height as the new phone width to preserve scale.
                // Assumes toolbar is hidden (auto-hides after 0.8 s — the common case).
                let curH      = win.frame.height
                let newPhoneW = curH
                let newPhoneH = (newPhoneW / newRatio).rounded()
                win.contentAspectRatio = NSSize(width: newRatio, height: 1)
                var newFrame = win.frame
                newFrame.size.width  = newPhoneW
                newFrame.size.height = newPhoneH
                newFrame.origin.y   -= newPhoneH - curH        // grow/shrink upward
                newFrame.origin.x   -= (newPhoneW - win.frame.width) / 2  // keep centered
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    win.animator().setFrame(newFrame, display: true)
                }
            } else {
                win.contentAspectRatio = NSSize(width: newRatio, height: 1)
            }
        }
    }

    // MARK: Title bar

    private var phoneTitleBar: some View {
        HStack(spacing: 8) {
            // Traffic-light clearance
            Color.clear.frame(width: 76, height: controlBarHeight)

            Spacer()

            // When popped out: only a retreat button stays in the main window.
            // Logs / Pin / Disconnect move to the popout window's overlay.
            if viewportIsPopped {
                GlassEffectContainer(spacing: 6) {
                    ToolbarButton(icon: "pip.exit", help: "Restore to Main Window") { retreatViewport() }
                        .glassEffectID("pip", in: titleBarNS)
                }
                .padding(.trailing, 8)
            } else {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ToolbarButton(icon: "pip.enter", help: "Pop Out Phone") { popViewport() }
                            .glassEffectID("pip", in: titleBarNS)
                        ToolbarButton(icon: "doc.text.magnifyingglass", help: "Debug Logs") {
                            showLogPanel.toggle()
                        }
                        .glassEffectID("logs", in: titleBarNS)
                        ToolbarButton(icon: windowManager.isPinned ? "pin.fill" : "pin",
                                      help: windowManager.isPinned ? "Unpin" : "Pin Window",
                                      tint: windowManager.isPinned ? .yellow : nil) {
                            windowManager.toggleAlwaysOnTop()
                        }
                        .glassEffectID("pin", in: titleBarNS)
                        if manager.state == .connected {
                            ToolbarButton(
                                icon: manager.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                help: manager.audioEnabled ? "Disable Audio" : "Enable Audio",
                                tint: manager.audioEnabled ? nil : .orange
                            ) {
                                manager.audioEnabled.toggle()
                            }
                            .glassEffectID("audio", in: titleBarNS)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            ToolbarButton(icon: "camera", help: "Screenshot") {
                                manager.takeScreenshot()
                            }
                            .glassEffectID("screenshot", in: titleBarNS)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            ToolbarButton(icon: "stop.circle.fill", help: "Disconnect", tint: .red) {
                                Task { await manager.disconnect() }
                            }
                            .glassEffectID("disconnect", in: titleBarNS)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .frame(height: controlBarHeight)
        .background { WindowDragArea() }
        .animation(.easeInOut(duration: 0.18), value: manager.state == .connected)
        .animation(.easeInOut(duration: 0.18), value: viewportIsPopped)
    }


    // MARK: Pop-out viewport

    private func popViewport() {
        guard manager.state == .connected, !viewportIsPopped else { return }
        let coord = PopoutCoordinator()
        // Seed the coordinator with the current video ratio so exit-fullscreen can snap correctly.
        let vs = manager.videoStream.videoSize
        coord.videoRatio = vs.width > 0 ? vs.width / vs.height : 9.0 / 16.0
        let pWin  = makePopoutWindow(coordinator: coord)
        let sWin  = makeControlSidebarWindow(relativeTo: pWin,
                                              onInteraction: { [weak coord] in coord?.sidebarDidInteract() })
        coord.setup(popout: pWin, sidebar: sWin)
        popoutWindow  = pWin
        sidebarWindow = sWin
        coordinator   = coord
        viewportIsPopped = true
    }

    private func retreatViewport() {
        guard viewportIsPopped else { return }
        viewportIsPopped = false
        popoutWindow?.delegate = nil
        coordinator = nil
        sidebarWindow?.close(); sidebarWindow = nil
        popoutWindow?.close();  popoutWindow  = nil
    }

    private func makePopoutWindow(coordinator: PopoutCoordinator) -> NSWindow {
        let vs     = manager.videoStream.videoSize
        let ratio: CGFloat = vs.width > 0 ? vs.width / vs.height : 9.0 / 16.0
        let winH: CGFloat  = 640
        let winW: CGFloat  = winH * ratio

        // Captured by the toolbar-expand callback below; set after window creation.
        var windowRef: NSWindow? = nil

        let rootView = PopoutView(
            manager:     manager,
            coordinator: coordinator,
            onRetreat: { retreatViewport() },
            onToolbarExpand: { expanded in
                guard let w = windowRef else { return }
                // Skip while fullscreen — frame dimensions are screen-sized there and
                // would corrupt the stored aspect ratio used to snap back on exit.
                guard !w.styleMask.contains(.fullScreen) else { return }
                let delta: CGFloat = expanded ? controlBarHeight : -controlBarHeight
                // contentAspectRatio must include the toolbar height so resize-dragging
                // maintains the correct phone ratio when the bar is visible.
                w.contentAspectRatio = NSSize(width: w.frame.width,
                                              height: w.frame.height + delta)
                var frame = w.frame
                frame.size.height += delta
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    w.animator().setFrame(frame, display: true)
                }
            }
        )
        .environment(windowManager)

        let hosting = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        window.title                      = manager.connectedDevice ?? "Phone"
        window.contentView                = hosting
        window.backgroundColor            = .clear
        window.isOpaque                   = false
        window.isReleasedWhenClosed       = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility            = .hidden
        // Traffic lights hidden by default; the hover-reveal toolbar brings them back.
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.alphaValue = 0
        }
        // Keep the phone's aspect ratio as the user resizes the popout window.
        window.contentAspectRatio         = NSSize(width: ratio, height: 1)
        window.collectionBehavior         = [.managed, .fullScreenPrimary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        windowRef = window   // allow the toolbar-expand callback to reference this window
        return window
    }

    /// Creates the floating hardware-control panel to the right (or left) of the popout window.
    private func makeControlSidebarWindow(relativeTo popoutWin: NSWindow,
                                          onInteraction: @escaping () -> Void) -> NSWindow {
        let rootView = ControlPanelView(controlSocket: manager.controlSocket,
                                        onInteraction: onInteraction)
            .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 70, height: 452),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        window.contentView          = hosting
        window.backgroundColor      = .clear
        window.isOpaque             = false
        window.hasShadow            = true
        window.isReleasedWhenClosed = false

        // Position to the right of the popout window; fall back to left if off-screen.
        let pf  = popoutWin.frame
        let sv  = (popoutWin.screen ?? NSScreen.main!).visibleFrame
        let sW: CGFloat = 70, sH: CGFloat = 452
        var x   = pf.maxX + 12
        if x + sW > sv.maxX { x = pf.minX - sW - 12 }
        let y   = max(sv.minY, min(sv.maxY - sH, pf.midY - sH / 2))
        window.setFrame(NSRect(x: x, y: y, width: sW, height: sH), display: false)
        window.orderFront(nil)
        return window
    }

    // MARK: Placeholder (while viewport lives in the popout window)

    private var popoutPlaceholder: some View {
        Button { retreatViewport() } label: {
            VStack(spacing: 16) {
                Image(systemName: "pip.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 72)
                    .glassEffect(.regular.interactive(), in: .circle)
                VStack(spacing: 6) {
                    Text("Viewing in separate window")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Click to restore")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Phone viewport

    @ViewBuilder
    private var phoneViewport: some View {
        switch manager.state {
        case .connected:
            if viewportIsPopped {
                popoutPlaceholder
            } else {
                GeometryReader { geo in
                    let ratio: CGFloat = manager.videoStream.videoSize.width > 0
                        ? manager.videoStream.videoSize.width / manager.videoStream.videoSize.height
                        : 9.0 / 16.0
                    let (fw, fh) = fitSize(in: geo.size, ratio: ratio)
                    VideoDisplayView(
                        displayLayer: manager.videoStream.displayLayer,
                        controlSocket: manager.controlSocket,
                        onFileDrop: { urls in Task { await manager.pushFiles(urls) } }
                    )
                    .frame(width: fw, height: fh)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

        case .connecting:
            phoneStateCard(
                icon: "smartphone",
                title: "Connecting",
                subtitle: "Setting up mirroring…",
                showSpinner: true
            )

        case .disconnected:
            disconnectedCard

        case .error(let msg):
            phoneStateCard(
                icon: "exclamationmark.triangle.fill",
                iconTint: .red,
                title: "Connection Failed",
                subtitle: msg,
                action: ("Try Again", { Task { await manager.disconnect() } })
            )
        }
    }

    private func phoneStateCard(
        icon: String,
        iconTint: Color? = nil,
        title: String,
        subtitle: String,
        showSpinner: Bool = false,
        action: (String, () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Group {
                if let tint = iconTint {
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular.tint(tint.opacity(0.2)), in: .circle)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular, in: .circle)
                }
            }
            VStack(spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showSpinner { ProgressView().controlSize(.regular) }
            if let (label, act) = action {
                Button { act() } label: {
                    Label(label, systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 160)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disconnectedCard: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: manager.availableDevices.isEmpty ? "cable.connector.slash" : "smartphone")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: 6) {
                Text(manager.availableDevices.isEmpty ? "No Device Found" : "Choose a Device")
                    .font(.system(size: 20, weight: .semibold))
                Text(manager.availableDevices.isEmpty
                     ? "Connect your Android phone via USB\nand enable USB debugging."
                     : "Select a device to start mirroring.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            if manager.availableDevices.isEmpty {
                Button { Task { await manager.refreshDevices() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 160).padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
            } else {
                DevicePickerView(
                    devices: manager.availableDevices,
                    onConnect: { device in Task { await manager.connect(deviceSerial: device) } },
                    onRefresh: { Task { await manager.refreshDevices() } }
                )
                .frame(maxWidth: 260)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls — three glass-pill groups displayed in one row

    private var controlsSection: some View {
        HardwareControlsBar(controlSocket: manager.controlSocket)
            .padding(.vertical, 10)
    }
}

// MARK: - fitSize helper

func fitSize(in available: CGSize, ratio: CGFloat) -> (CGFloat, CGFloat) {
    available.width / available.height > ratio
        ? (available.height * ratio, available.height)
        : (available.width, available.width / ratio)
}
