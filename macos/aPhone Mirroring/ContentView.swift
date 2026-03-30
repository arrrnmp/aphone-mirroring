//
//  ContentView.swift
//  aPhone Mirroring
//
//  Root split-panel layout:
//    Left  — Phone panel: Liquid Glass background, phone viewport, controls tab bar.
//    Right — Content panel: pill tab bar (Messages / Photos / Calls), auth overlay,
//            placeholder tab content.
//
//  All three right-panel tabs require biometric / password verification.
//  Auth locks after 2 min of inactivity or 2 min backgrounded.
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Navigation notifications

private extension NSNotification.Name {
    /// Post to navigate the Messages tab to a specific phone number's thread.
    static let navigateToSMS = NSNotification.Name("aphone.navigateToSMS")
}

// MARK: - ContentView (root)

struct ContentView: View {

    @StateObject private var manager  = ScrcpyManager()
    @StateObject private var appLog   = AppLog.shared
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
            { _ in auth.handleAppResigned() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            { _ in auth.handleAppActivated() }
    }
}

// MARK: - PhonePanelView

private struct PhonePanelView: View {

    @ObservedObject var manager: ScrcpyManager
    @ObservedObject var appLog: AppLog
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notif in
            let win = notif.object as? NSWindow
            if win === popoutWindow || win === sidebarWindow {
                retreatViewport()
            }
        }
        // Keep the popout window in sync when the device rotates.
        .onChange(of: manager.videoStream.videoSize) { oldSize, newSize in
            guard viewportIsPopped, let win = popoutWindow, newSize.width > 0 else { return }
            let newRatio = newSize.width / newSize.height
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
        let pWin  = makePopoutWindow()
        let sWin  = makeControlSidebarWindow(relativeTo: pWin,
                                              onInteraction: { [weak coord] in coord?.sidebarDidInteract() })
        coord.setup(popout: pWin, sidebar: sWin)
        popoutWindow = pWin
        sidebarWindow = sWin
        coordinator = coord
        viewportIsPopped = true
    }

    private func retreatViewport() {
        guard viewportIsPopped else { return }
        viewportIsPopped = false          // set first to prevent re-entry from notification
        popoutWindow?.delegate = nil      // detach coordinator before closing
        coordinator = nil
        sidebarWindow?.close(); sidebarWindow = nil
        popoutWindow?.close();  popoutWindow  = nil
    }

    private func makePopoutWindow() -> NSWindow {
        let vs     = manager.videoStream.videoSize
        let ratio: CGFloat = vs.width > 0 ? vs.width / vs.height : 9.0 / 16.0
        let winH: CGFloat  = 640
        let winW: CGFloat  = winH * ratio

        // Captured by the toolbar-expand callback below; set after window creation.
        var windowRef: NSWindow? = nil

        let rootView = PopoutView(
            manager:   manager,
            onRetreat: { retreatViewport() },
            onToolbarExpand: { expanded in
                guard let w = windowRef else { return }
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
        window.backgroundColor            = .black
        window.isReleasedWhenClosed       = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility            = .hidden
        // Traffic lights hidden by default; the hover-reveal toolbar brings them back.
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.alphaValue = 0
        }
        // Keep the phone's aspect ratio as the user resizes the popout window.
        window.contentAspectRatio         = NSSize(width: ratio, height: 1)
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

    private func fitSize(in available: CGSize, ratio: CGFloat) -> (CGFloat, CGFloat) {
        let availRatio = available.width / available.height
        if availRatio > ratio {
            return (available.height * ratio, available.height)
        } else {
            return (available.width, available.width / ratio)
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
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // Audio: Volume Up / Down / Mute
                    ctrlPill {
                        ctrlButton("speaker.plus",  "Vol +") { manager.controlSocket.sendVolumeUp() }
                        ctrlButton("speaker.minus", "Vol −") { manager.controlSocket.sendVolumeDown() }
                        ctrlButton("speaker.slash", "Mute")  { manager.controlSocket.sendMute() }
                    }
                    // Navigation: Back / Home / Recents
                    ctrlPill {
                        ctrlButton("arrow.left",  "Back")    { manager.controlSocket.sendBackButton() }
                        ctrlButton("house",        "Home")    { manager.controlSocket.sendHomeButton() }
                        ctrlButton("square.stack", "Recents") { manager.controlSocket.sendAppSwitch() }
                    }
                    // Device: Power / Rotate
                    ctrlPill {
                        ctrlButton("power",        "Power")  { manager.controlSocket.sendPowerButton() }
                        ctrlButton("rotate.right", "Rotate") { manager.controlSocket.sendRotateDevice() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    /// A glass-capsule container for a group of hardware-control buttons.
    private func ctrlPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func ctrlButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

// MARK: - ContentPanelView

private struct ContentPanelView: View {

    @ObservedObject var bridge: DataBridgeClient
    @ObservedObject var btManager: BluetoothPairingManager
    @Environment(AuthManager.self) private var auth
    @State private var selectedTab: PhoneTab = .messages
    @State private var sidebarWidth: CGFloat = 232
    @State private var navigateSMSPhone: String? = nil
    @Namespace private var tabNS

    private static let bg = Color(white: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — single glass surface with sliding selection indicator.
            topTabBar
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Bluetooth pairing banner — shown until paired
            btPairingBanner

            ZStack {
                if !auth.isLocked {
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .simultaneousGesture(TapGesture().onEnded { auth.userDidInteract() })
                }
                if auth.isLocked {
                    LockedView().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: auth.isLocked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.bg.ignoresSafeArea())
        // Switch to Messages tab and thread when a "navigate to SMS" action fires
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSMS)) { notif in
            let phone = notif.userInfo?["phone"] as? String
            withAnimation(.smooth(duration: 0.28)) { selectedTab = .messages }
            navigateSMSPhone = phone
        }
        // Show / dismiss the floating call window when an active call starts or ends
        .onChange(of: bridge.activeCall) { _, call in
            if let call {
                CallWindowController.shared.show(call: call, bridge: bridge)
            } else {
                CallWindowController.shared.dismiss()
            }
        }
    }

    // MARK: - Top tab bar

    // One glass surface for the whole bar; a matchedGeometryEffect capsule slides
    // between items to indicate selection — no per-item glass.
    private var topTabBar: some View {
        HStack(spacing: 0) {
            ForEach(PhoneTab.allCases, id: \.self) { tab in
                tabBarItem(tab)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }

    private func tabBarItem(_ tab: PhoneTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            if auth.isLocked {
                Task { await auth.authenticate() }
            } else {
                withAnimation(.smooth(duration: 0.28)) { selectedTab = tab }
                auth.userDidInteract()
            }
        } label: {
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .matchedGeometryEffect(id: "tab-selection", in: tabNS)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.28), value: selected)
    }

    // MARK: - Bluetooth pairing banner

    @ViewBuilder
    private var btPairingBanner: some View {
        switch btManager.status {
        case .checking:
            btBannerShell {
                ProgressView().controlSize(.mini).tint(.secondary)
                Text("Checking Bluetooth pairing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .notPaired(let name):
            btBannerShell {
                Image(systemName: "bluetooth")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair \(name) via Bluetooth")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Required for routing call audio to your Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await btManager.startPairing() }
                } label: {
                    Text("Pair Now")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

        case .pairing(let name):
            btBannerShell {
                ProgressView().controlSize(.mini).tint(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pairing with \(name)…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Accept the pairing request on your phone")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

        case .unavailable(let msg):
            btBannerShell {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    btManager.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .idle, .paired:
            EmptyView()
        }
    }

    private func btBannerShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.18).clipShape(RoundedRectangle(cornerRadius: 10)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.smooth(duration: 0.3), value: btManager.status == .paired)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .messages: MessagesTabView(listWidth: $sidebarWidth, bridge: bridge, navigateSMSPhone: $navigateSMSPhone)
        case .photos:   PhotosTabView(bridge: bridge)
        case .calls:    CallsTabView(listWidth: $sidebarWidth, bridge: bridge)
        case .contacts: ContactsTabView(listWidth: $sidebarWidth, bridge: bridge)
        }
    }
}


// MARK: - PhoneTab

private enum PhoneTab: CaseIterable {
    case messages, photos, contacts, calls

    var title: String {
        switch self {
        case .messages: "Messages"
        case .photos:   "Photos"
        case .contacts: "Contacts"
        case .calls:    "Calls"
        }
    }
}

// MARK: - LockedView

private struct LockedView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular, in: .circle)

                VStack(spacing: 8) {
                    Text("Verification Required")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Your phone data is protected.\nVerify to view messages, photos, and calls.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 280)
                }

                Button {
                    Task { await auth.authenticate() }
                } label: {
                    Label(auth.unlockLabel, systemImage: auth.unlockIcon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 180)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .disabled(auth.isAuthenticating)
                .overlay {
                    if auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Messages tab

private struct MessagesTabView: View {
    @Binding var listWidth: CGFloat
    @ObservedObject var bridge: DataBridgeClient
    @Binding var navigateSMSPhone: String?
    @State private var selectedThread: BridgeThread? = nil
    @State private var pendingPhone: String? = nil   // non-nil → show NewConversationPanel
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredThreads: [BridgeThread] {
        guard !searchText.isEmpty else { return bridge.threads }
        return bridge.threads.filter {
            $0.contactName.localizedCaseInsensitiveContains(searchText) ||
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — thread list
            ThreadListPanel(
                threads: filteredThreads,
                selectedThread: $selectedThread,
                searchText: $searchText,
                onCompose: {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedThread = nil
                        pendingPhone = ""
                    }
                }
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            // Right panel — conversation detail or new conversation
            Group {
                if let phone = pendingPhone {
                    NewConversationPanel(
                        initialPhone: phone,
                        bridge: bridge,
                        onSent: {
                            // Called after sending — clear pending (new_sms event will refresh threads)
                            pendingPhone = nil
                        },
                        onCancel: {
                            withAnimation(.smooth(duration: 0.2)) { pendingPhone = nil }
                        }
                    )
                    .id("pending-\(phone)")
                } else if let thread = selectedThread {
                    ConversationPanel(
                        thread: thread,
                        messages: bridge.messages[thread.threadId] ?? [],
                        bridge: bridge
                    )
                    .id(thread.threadId)
                } else {
                    noSelectionPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { totalWidth in
            let maxAllowed = min(maxListWidth, totalWidth - minContentWidth - 20)
            if listWidth > maxAllowed { listWidth = max(minListWidth, maxAllowed) }
        }
        // When a thread is selected, dismiss compose panel and fetch messages
        .onChange(of: selectedThread?.threadId) { _, threadId in
            if let id = threadId {
                if pendingPhone != nil { pendingPhone = nil }
                bridge.fetchMessages(threadId: id)
                bridge.markRead(threadId: id)
            }
        }
        // Auto-select first thread once data loads (only when no pending compose)
        .onChange(of: bridge.threads) { _, threads in
            if selectedThread == nil, pendingPhone == nil, let first = threads.first {
                selectedThread = first
            }
        }
        // Navigate to thread when arriving from another tab (binding set before view appears)
        .onAppear { applyNavigateSMS(navigateSMSPhone) }
        .onChange(of: navigateSMSPhone) { _, phone in applyNavigateSMS(phone) }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView()
                    .controlSize(.regular)
            } else if bridge.threads.isEmpty {
                Image(systemName: "message")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.isConnected ? "No messages" : "Connect your phone to view messages")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "message")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select a conversation")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyNavigateSMS(_ phone: String?) {
        guard let phone, !phone.isEmpty else { return }
        navigateSMSPhone = nil   // consume so repeat taps re-trigger onChange
        let digits = phone.filter(\.isNumber)
        if let match = bridge.threads.first(where: { $0.contactPhone.filter(\.isNumber) == digits }) {
            withAnimation(.smooth(duration: 0.2)) {
                selectedThread = match
                pendingPhone = nil
            }
        } else {
            withAnimation(.smooth(duration: 0.2)) {
                selectedThread = nil
                pendingPhone = phone
            }
        }
    }
}

// Thin 1pt line with an 8pt invisible hit target; drag to resize the left panel.
private struct PanelResizeDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var startWidth: CGFloat = 0
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isHovered ? 0.18 : 0.07))
            .frame(width: 1)
            .padding(.vertical, 16)
            .frame(width: 8)            // wider invisible hit area
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let proposed = startWidth + value.translation.width
                        width = max(minWidth, min(maxWidth, proposed))
                    }
                    .onEnded { _ in startWidth = width }
            )
            .onAppear { startWidth = width }
    }
}

// MARK: Thread list panel

private struct ThreadListPanel: View {
    let threads: [BridgeThread]
    @Binding var selectedThread: BridgeThread?
    @Binding var searchText: String
    let onCompose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Search bar + compose button row
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Message")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(threads) { thread in
                        ThreadRow(
                            thread: thread,
                            isSelected: selectedThread?.id == thread.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedThread = thread }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

private struct ThreadRow: View {
    let thread: BridgeThread
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hue: thread.hue, saturation: 0.6, brightness: 0.75))
                    Text(thread.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.contactName)
                            .font(.system(size: 13, weight: thread.unreadCount > 0 ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(thread.timeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(thread.preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if thread.unreadCount > 0 {
                            ZStack {
                                Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                                Text("\(thread.unreadCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

// MARK: Conversation panel

private struct ConversationPanel: View {
    let thread: BridgeThread
    let messages: [BridgeMessage]
    let bridge: DataBridgeClient
    @State private var draftText = ""

    var body: some View {
        VStack(spacing: 0) {
            contactHeader

            Divider().opacity(0.1)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(groupedByDay(messages), id: \.0) { dayLabel, dayMessages in
                            DayDivider(label: dayLabel)
                            VStack(spacing: 6) {
                                ForEach(dayMessages) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.messageId)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) }
                    }
                }
            }

            Divider().opacity(0.1)

            messageInputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contactHeader: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color(hue: thread.hue, saturation: 0.6, brightness: 0.75))
                Text(thread.initials)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            Text(thread.contactName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    // Plain fill input bar — avoids glass-on-glass inside the panel
    private var messageInputBar: some View {
        HStack(spacing: 8) {
            TextField("iMessage", text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.08))
                )
            if !draftText.isEmpty {
                Button {
                    bridge.sendSMS(to: thread.contactPhone, body: draftText)
                    draftText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.smooth(duration: 0.2), value: draftText.isEmpty)
    }
}

// MARK: New conversation (no existing thread)

private struct NewConversationPanel: View {
    let initialPhone: String
    let bridge: DataBridgeClient
    let onSent: () -> Void
    let onCancel: () -> Void

    @State private var recipientPhone: String
    @State private var draftText = ""

    init(initialPhone: String, bridge: DataBridgeClient,
         onSent: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initialPhone = initialPhone
        self.bridge = bridge
        self.onSent = onSent
        self.onCancel = onCancel
        self._recipientPhone = State(initialValue: initialPhone)
    }

    var body: some View {
        VStack(spacing: 0) {
            // To: field + cancel button
            HStack(spacing: 8) {
                Text("To:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Phone number", text: $recipientPhone)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.1)

            Spacer()

            Text("No messages yet")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Spacer()

            Divider().opacity(0.1)

            // Input bar
            HStack(spacing: 8) {
                TextField("Text Message", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.08)))
                if !draftText.isEmpty {
                    Button {
                        let phone = recipientPhone.trimmingCharacters(in: .whitespaces)
                        guard !phone.isEmpty else { return }
                        bridge.sendSMS(to: phone, body: draftText)
                        draftText = ""
                        onSent()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .animation(.smooth(duration: 0.2), value: draftText.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageBubble: View {
    let message: BridgeMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .font(.system(size: 13))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(message.isFromMe ? Color.blue : Color.white.opacity(0.12))
                    )
                Text(message.timeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}

private struct DayDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

/// Groups an array of messages into (dayLabel, messages) sections.
private func groupedByDay(_ messages: [BridgeMessage]) -> [(String, [BridgeMessage])] {
    var groups: [(String, [BridgeMessage])] = []
    var currentLabel: String?
    var currentGroup: [BridgeMessage] = []

    for msg in messages {
        let label = messageDayLabel(epochMillis: msg.timestamp)
        if label != currentLabel {
            if let current = currentLabel, !currentGroup.isEmpty {
                groups.append((current, currentGroup))
            }
            currentLabel = label
            currentGroup = [msg]
        } else {
            currentGroup.append(msg)
        }
    }
    if let current = currentLabel, !currentGroup.isEmpty {
        groups.append((current, currentGroup))
    }
    return groups
}

private func messageDayLabel(epochMillis: Double) -> String {
    let date = Date(timeIntervalSince1970: epochMillis / 1000.0)
    let cal = Calendar.current
    if cal.isDateInToday(date)     { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
    if daysAgo < 7 {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        return fmt.string(from: date)
    }
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .none
    return fmt.string(from: date)
}

// MARK: - Photos tab

private struct PhotosTabView: View {
    @ObservedObject var bridge: DataBridgeClient
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 240), spacing: 8)]

    var body: some View {
        Group {
            if bridge.photos.isEmpty {
                VStack(spacing: 12) {
                    if bridge.isLoading {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(bridge.isConnected ? "No photos" : "Connect your phone to view photos")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(bridge.photos) { photo in
                            PhotoCell(photo: photo, bridge: bridge)
                        }
                        // Sentinel: when this appears in the viewport, load the next page
                        if bridge.photosHasMore {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .onAppear { bridge.loadMorePhotos() }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PhotoCell: View {
    let photo: BridgePhoto
    let bridge: DataBridgeClient

    var body: some View {
        Button { bridge.openFullPhoto(mediaId: photo.mediaId) } label: {
            // Rectangle with aspectRatio(1) is the reliable way to get square cells in LazyVGrid
            Rectangle()
                .fill(Color(white: 0.22))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let img = photo.thumbnailImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.localURL != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green.opacity(0.85))
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onAppear { bridge.fetchThumbnail(mediaId: photo.mediaId) }
    }
}

// MARK: - Calls tab

private struct CallsTabView: View {
    @Binding var listWidth: CGFloat
    @ObservedObject var bridge: DataBridgeClient
    @State private var selectedCall: BridgeCall? = nil
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredCalls: [BridgeCall] {
        guard !searchText.isEmpty else { return bridge.calls }
        return bridge.calls.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            CallListPanel(
                calls: filteredCalls,
                selectedCall: $selectedCall,
                searchText: $searchText
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            Group {
                if let call = selectedCall {
                    ContactDetailPanel(call: call, allCalls: bridge.calls, bridge: bridge)
                        .id(call.callId)
                } else {
                    noSelectionView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { totalWidth in
            let maxAllowed = min(maxListWidth, totalWidth - minContentWidth - 20)
            if listWidth > maxAllowed { listWidth = max(minListWidth, maxAllowed) }
        }
        .onChange(of: bridge.calls) { _, calls in
            if selectedCall == nil, let first = calls.first { selectedCall = first }
        }
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "phone")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.calls.isEmpty && !bridge.isConnected
                     ? "Connect your phone to view calls"
                     : "Select a contact")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Call list panel

private struct CallListPanel: View {
    let calls: [BridgeCall]
    @Binding var selectedCall: BridgeCall?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(calls) { call in
                        CallRow(
                            call: call,
                            isSelected: selectedCall?.id == call.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedCall = call }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

private struct CallRow: View {
    let call: BridgeCall
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hue: call.hue, saturation: 0.55, brightness: 0.70))
                    Text(call.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(call.displayName)
                        .font(.system(size: 13, weight: call.isMissed ? .semibold : .medium))
                        .foregroundStyle(call.isMissed ? .red : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: call.isOutgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(call.isMissed ? .red : call.isOutgoing ? Color.accentColor : .green)
                        if let dur = call.durationLabel {
                            Text(dur).font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Text("Missed").font(.system(size: 12)).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                }

                Spacer()

                Text(call.timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

// MARK: Contact detail panel

private struct ContactDetailPanel: View {
    let call: BridgeCall
    let allCalls: [BridgeCall]
    let bridge: DataBridgeClient
    @State private var detailTab = 0
    @State private var showMessageMenu = false
    @Namespace private var detailNS

    private var recentCalls: [BridgeCall] {
        allCalls.filter { $0.displayName == call.displayName }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Contact-tinted gradient — bleeds from top, fades to the panel base by midpoint
            LinearGradient(
                colors: [
                    Color(hue: call.hue, saturation: 0.45, brightness: 0.28),
                    Color(white: 0.17)
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {

                    // ── Avatar + name ─────────────────────────────────────────
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(hue: call.hue, saturation: 0.5, brightness: 0.72))
                            Text(call.initials)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 90, height: 90)
                        .shadow(
                            color: Color(hue: call.hue, saturation: 0.6, brightness: 0.5).opacity(0.5),
                            radius: 20, x: 0, y: 8
                        )

                        Text(call.displayName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                    // ── Action buttons — Message (SMS) · Call · More ──
                    GlassEffectContainer(spacing: 16) {
                        HStack(spacing: 16) {
                            smsActionButton
                            callActionButton
                            moreActionButton
                        }
                    }
                    .padding(.bottom, 26)

                    // ── Segmented control — Liquid Glass pills (interactive control) ──
                    GlassEffectContainer(spacing: 2) {
                        HStack(spacing: 2) {
                            detailTabItem(0, "Details")
                            detailTabItem(1, "Recent Calls")
                        }
                    }
                    .padding(.bottom, 16)

                    // ── Tab content ───────────────────────────────────────────
                    Group {
                        if detailTab == 0 {
                            detailsSection
                                .transition(.opacity)
                        } else {
                            recentCallsSection
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.22), value: detailTab)
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // SMS button — opens the in-app SMS conversation directly
    private var smsActionButton: some View {
        VStack(spacing: 7) {
            Button {
                NotificationCenter.default.post(
                    name: .navigateToSMS, object: nil, userInfo: ["phone": call.number]
                )
            } label: {
                Image(systemName: "message.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Text("Message")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // Call button — directly initiates the call
    private var callActionButton: some View {
        VStack(spacing: 7) {
            Button { bridge.placeCall(call.number) } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            Text("Call")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // More button — shows all third-party app options (WhatsApp, Signal, etc.)
    private var moreActionButton: some View {
        VStack(spacing: 7) {
            Button {
                bridge.fetchContactApps(phone: call.number, name: call.displayName)
                showMessageMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .popover(isPresented: $showMessageMenu, arrowEdge: .bottom) {
                AppActionsMenu(phone: call.number, bridge: bridge,
                               onDismiss: { showMessageMenu = false })
            }
            Text("Other")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func detailTabItem(_ idx: Int, _ title: String) -> some View {
        let selected = detailTab == idx
        return Button {
            withAnimation(.smooth(duration: 0.25)) { detailTab = idx }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID(selected ? "detail-active" : "detail-\(idx)", in: detailNS)
    }

    private var detailsSection: some View {
        VStack(spacing: 0) {
            detailRow(icon: "phone", label: "Mobile", value: call.number)
            Divider().opacity(0.1).padding(.leading, 42)
            detailRow(icon: "clock", label: "Last call", value: call.timeLabel)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.20))
        )
    }

    private var recentCallsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentCalls.enumerated()), id: \.element.id) { idx, rec in
                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                recentCallRow(rec)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.20))
        )
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func recentCallRow(_ rec: BridgeCall) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rec.isOutgoing ? "phone.arrow.up.right"
                                             : "phone.arrow.down.left")
                .font(.system(size: 12))
                .foregroundStyle(rec.isMissed   ? .red
                                 : rec.isOutgoing ? Color.accentColor : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.isMissed ? "Missed" : rec.isOutgoing ? "Outgoing" : "Incoming")
                    .font(.system(size: 13))
                    .foregroundStyle(rec.isMissed ? .red : .primary)
                if let dur = rec.durationLabel {
                    Text(dur).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(rec.timeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Contacts tab

private struct ContactsTabView: View {
    @Binding var listWidth: CGFloat
    @ObservedObject var bridge: DataBridgeClient
    @State private var selectedContact: BridgeContact? = nil
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredContacts: [BridgeContact] {
        guard !searchText.isEmpty else { return bridge.contacts }
        return bridge.contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ContactListPanel(
                contacts: filteredContacts,
                selectedContact: $selectedContact,
                searchText: $searchText
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            Group {
                if let contact = selectedContact {
                    ContactInfoPanel(contact: contact, bridge: bridge)
                        .id(contact.contactId)
                } else {
                    noSelectionView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { totalWidth in
            let maxAllowed = min(maxListWidth, totalWidth - minContentWidth - 20)
            if listWidth > maxAllowed { listWidth = max(minListWidth, maxAllowed) }
        }
        .onChange(of: bridge.contacts) { _, contacts in
            if selectedContact == nil, let first = contacts.first { selectedContact = first }
        }
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.contacts.isEmpty && !bridge.isConnected
                     ? "Connect your phone to view contacts"
                     : "Select a contact")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContactListPanel: View {
    let contacts: [BridgeContact]
    @Binding var selectedContact: BridgeContact?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(contacts) { contact in
                        ContactRow(
                            contact: contact,
                            isSelected: selectedContact?.id == contact.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedContact = contact }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

private struct ContactRow: View {
    let contact: BridgeContact
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hue: contact.hue, saturation: 0.6, brightness: 0.75))
                    Text(contact.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let phone = contact.phoneNumbers.first {
                        Text(phone)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

private struct ContactInfoPanel: View {
    let contact: BridgeContact
    let bridge: DataBridgeClient
    @State private var showMessageMenu = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(hue: contact.hue, saturation: 0.45, brightness: 0.28),
                    Color(white: 0.17)
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Avatar + name
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(hue: contact.hue, saturation: 0.5, brightness: 0.72))
                            Text(contact.initials)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 90, height: 90)
                        .shadow(
                            color: Color(hue: contact.hue, saturation: 0.6, brightness: 0.5).opacity(0.5),
                            radius: 20, x: 0, y: 8
                        )
                        Text(contact.displayName)
                            .font(.system(size: 22, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                    // Action buttons — Message (SMS) · Call · More
                    GlassEffectContainer(spacing: 16) {
                        HStack(spacing: 16) {
                            // Message → SMS in-app directly
                            VStack(spacing: 7) {
                                Button {
                                    let phone = contact.phoneNumbers.first ?? ""
                                    NotificationCenter.default.post(
                                        name: .navigateToSMS, object: nil,
                                        userInfo: ["phone": phone]
                                    )
                                } label: {
                                    Image(systemName: "message.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                Text("Message")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Call — directly initiates the call
                            VStack(spacing: 7) {
                                Button {
                                    if let phone = contact.phoneNumbers.first {
                                        bridge.placeCall(phone)
                                    }
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                Text("Call")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // More — third-party app actions
                            VStack(spacing: 7) {
                                Button {
                                    let phone = contact.phoneNumbers.first ?? ""
                                    bridge.fetchContactApps(phone: phone, name: contact.displayName)
                                    showMessageMenu.toggle()
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .popover(isPresented: $showMessageMenu, arrowEdge: .bottom) {
                                    AppActionsMenu(
                                        phone: contact.phoneNumbers.first ?? "",
                                        bridge: bridge,
                                        onDismiss: { showMessageMenu = false }
                                    )
                                }
                                Text("Other")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.bottom, 26)

                    // Organisation
                    if let org = contact.organization {
                        let detail = [contact.jobTitle, org].compactMap { $0 }.joined(separator: " · ")
                        infoSection(title: "Organisation") {
                            infoRow(icon: "building.2", value: detail)
                        }
                        .padding(.bottom, 12)
                    }

                    // Phone numbers — deduplicated by digits-only comparison
                    let dedupedPhones: [String] = {
                        var seen = Set<String>()
                        return contact.phoneNumbers.filter { seen.insert($0.filter(\.isNumber)).inserted }
                    }()
                    if !dedupedPhones.isEmpty {
                        infoSection(title: "Phone") {
                            ForEach(Array(dedupedPhones.enumerated()), id: \.offset) { idx, num in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRow(icon: "phone", value: num)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Emails — tappable to open a draft in the default mail app
                    if !contact.emails.isEmpty {
                        infoSection(title: "Email") {
                            ForEach(Array(contact.emails.enumerated()), id: \.offset) { (idx: Int, email: String) in
                                VStack(spacing: 0) {
                                    if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                    Button {
                                        if let url = URL(string: "mailto:\(email)") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        infoRow(icon: "envelope", value: email)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open in Mail")
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Birthday
                    if let bday = contact.birthday {
                        infoSection(title: "Birthday") {
                            infoRow(icon: "gift", value: bday)
                        }
                        .padding(.bottom, 12)
                    }

                    // Addresses
                    if !contact.addresses.isEmpty {
                        infoSection(title: "Address") {
                            ForEach(Array(contact.addresses.enumerated()), id: \.offset) { idx, addr in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRowMultiline(icon: "mappin", value: addr)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Websites
                    if !contact.websites.isEmpty {
                        infoSection(title: "Website") {
                            ForEach(Array(contact.websites.enumerated()), id: \.offset) { idx, url in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRow(icon: "globe", value: url)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Notes
                    if let notes = contact.notes {
                        infoSection(title: "Notes") {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .padding(.top, 1)
                                Text(notes)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .padding(.bottom, 16)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoSection<Content: View>(title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.20)))
    }

    private func infoRow(icon: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func infoRowMultiline(icon: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - App Actions Menu

/// Popover for the "Other" button — shows only dynamically-detected third-party app actions.
private struct AppActionsMenu: View {
    let phone: String
    @ObservedObject var bridge: DataBridgeClient
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

// MARK: - Shared sub-views (DevicePicker, LogPanel, LogEntry)

private struct DevicePickerView: View {
    let devices: [String]
    let onConnect: (String) -> Void
    let onRefresh: () -> Void
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { idx, dev in
                        DeviceRowView(device: dev) { onConnect(dev) }
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .glassEffectID("dev-\(idx)", in: ns)
                    }
                }
            }
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DeviceRowView: View {
    let device: String
    let action: () -> Void

    private var displayName: String {
        if let p = device.firstIndex(of: "(") {
            return String(device[device.startIndex..<p]).trimmingCharacters(in: .whitespaces)
        }
        return device
    }
    private var serial: String? {
        guard let o = device.firstIndex(of: "("),
              let c = device.firstIndex(of: ")") else { return nil }
        let s = String(device[device.index(after: o)..<c])
        return s.count > 12 ? String(s.prefix(10)) + "…" : s
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "smartphone")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if let s = serial {
                        Text(s)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LogPanelView: View {
    @ObservedObject var appLog: AppLog
    let onClose: () -> Void

    @State private var isAtBottom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Debug Log", systemImage: "terminal.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Button("Clear") { appLog.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button { onClose() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.2)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appLog.entries) { entry in
                            LogEntryRowView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .frame(height: 220)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 20
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onChange(of: appLog.entries.count) { _, _ in
                    guard isAtBottom, let last = appLog.entries.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

private struct LogEntryRowView: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.6))
                .fixedSize()
            Text(entry.level.icon).font(.system(size: 10))
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - PopoutCoordinator

/// Manages the floating hardware-control sidebar window relative to the popout phone window.
///
/// Responsibilities:
///   • Repositions the sidebar whenever the popout window moves.
///   • Fades the sidebar to 0 alpha while the popout is being dragged, restores after settle.
///   • Fades the sidebar to 0.35 alpha after 4 s of idle interaction.
///   • Hides the sidebar when the popout loses key status; shows it when key is regained.
///   • Hides / shows the sidebar on miniaturize / deminiaturize.
final class PopoutCoordinator: NSObject, NSWindowDelegate {

    private(set) weak var sidebarWindow: NSWindow?
    private var idleTimer:   Timer?
    private var settleTimer: Timer?
    private var isDragging = false
    private var eventMonitor: Any?

    func setup(popout: NSWindow, sidebar: NSWindow) {
        sidebarWindow = sidebar
        popout.delegate = self

        // Observe window-will-move (drag start) — no delegate method for this.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillMove(_:)),
            name: NSWindow.willMoveNotification, object: popout
        )

        // Reset idle timer on any mouse activity in the sidebar.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window === self?.sidebarWindow { self?.resetIdleTimer() }
            return event
        }

        resetIdleTimer()
    }

    /// Called by sidebar buttons to reset the idle-fade timer.
    func sidebarDidInteract() { resetIdleTimer() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        idleTimer?.invalidate()
        settleTimer?.invalidate()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let popout = notification.object as? NSWindow else { return }
        repositionSidebar(relativeTo: popout)
        // Debounce: restore sidebar alpha shortly after dragging stops.
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
        sidebarWindow?.orderFront(nil)
        resetIdleTimer()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Only hide if focus moved to a window other than the sidebar itself.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if NSApp.keyWindow !== self.sidebarWindow {
                self.sidebarWindow?.orderOut(nil)
            }
        }
    }

    // MARK: Drag detection

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

// MARK: - ToolbarHoverArea

/// Transparent NSViewRepresentable that tracks when the mouse enters/exits the top
/// `topHeight` points of the hosting window. Passes clicks through via hitTest → nil.
private struct ToolbarHoverArea: NSViewRepresentable {
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
private struct TrafficLightController: NSViewRepresentable {
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

// MARK: - PopoutView
// Full-screen phone viewport hosted in a separate NSWindow when the user pops out the phone.
// Utility buttons (retreat, logs, pin, disconnect) hover-reveal from the top edge.
// The hardware-control sidebar (ControlPanelView) is a separate NSWindow managed by PhonePanelView.

private struct PopoutView: View {

    @ObservedObject var manager:  ScrcpyManager
    @Environment(WindowManager.self) private var windowManager
    let onRetreat:       () -> Void
    /// Called when the toolbar is shown/hidden so the window can grow/shrink upward.
    let onToolbarExpand: (Bool) -> Void

    @State private var showLogPanel    = false
    @State private var toolbarVisible  = false
    @State private var toolbarHideTask: Task<Void, Never>? = nil
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            // ── Hover-reveal title bar ─────────────────────────────────────────
            // Sits above the video; the window grows upward to accommodate it,
            // so the phone viewport never shifts on screen.
            if toolbarVisible {
                ZStack {
                    WindowDragArea()
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 76)
                        Spacer()
                        GlassEffectContainer(spacing: 6) {
                            HStack(spacing: 6) {
                                ToolbarButton(icon: "pip.exit", help: "Restore to Main Window") { onRetreat() }
                                    .glassEffectID("retreat", in: ns)
                                ToolbarButton(icon: "doc.text.magnifyingglass", help: "Debug Logs") { showLogPanel.toggle() }
                                    .glassEffectID("logs", in: ns)
                                ToolbarButton(icon: windowManager.isPinned ? "pin.fill" : "pin",
                                              help: windowManager.isPinned ? "Unpin" : "Always on Top",
                                              tint: windowManager.isPinned ? .yellow : nil) {
                                    windowManager.toggleAlwaysOnTop()
                                }
                                .glassEffectID("pin", in: ns)
                                ToolbarButton(
                                    icon: manager.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    help: manager.audioEnabled ? "Disable Audio" : "Enable Audio",
                                    tint: manager.audioEnabled ? nil : .orange
                                ) {
                                    manager.audioEnabled.toggle()
                                }
                                .glassEffectID("audio", in: ns)
                                ToolbarButton(icon: "camera", help: "Screenshot") { manager.takeScreenshot() }
                                    .glassEffectID("screenshot", in: ns)
                                ToolbarButton(icon: "stop.circle.fill", help: "Disconnect", tint: .red) {
                                    Task { await manager.disconnect() }
                                }
                                .glassEffectID("disconnect", in: ns)
                            }
                            .padding(.trailing, 8)
                        }
                    }
                }
                .frame(height: controlBarHeight)
                .background(.ultraThinMaterial)
                .transition(.opacity)
            }

            // ── Phone video viewport ───────────────────────────────────────────
            GeometryReader { geo in
                let vs    = manager.videoStream.videoSize
                let ratio: CGFloat = vs.width > 0 ? vs.width / vs.height : 9.0 / 16.0
                let (fw, fh) = fitSize(in: geo.size, ratio: ratio)
                VideoDisplayView(
                    displayLayer:  manager.videoStream.displayLayer,
                    controlSocket: manager.controlSocket,
                    onFileDrop:    { urls in Task { await manager.pushFiles(urls) } }
                )
                .frame(width: fw, height: fh)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
        }
        // Hover detection — transparent, clicks pass through to video / buttons.
        .overlay(alignment: .top) {
            ToolbarHoverArea(topHeight: 50, onEnter: { showToolbar() }, onExit: { scheduleToolbarHide() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .background { TrafficLightController(show: toolbarVisible) }
        .overlay(alignment: .bottom) {
            if showLogPanel {
                LogPanelView(appLog: AppLog.shared) { showLogPanel = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let flash = manager.screenshotFlash {
                ScreenshotFlashView(image: flash.image, url: flash.url)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                    .id(flash.id)
            }
        }
        .ignoresSafeArea(edges: .all)
        .animation(.easeInOut(duration: 0.22), value: toolbarVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLogPanel)
        .onChange(of: toolbarVisible) { _, expanded in onToolbarExpand(expanded) }
        .preferredColorScheme(.dark)
        .background(Color.black)
    }

    // MARK: Toolbar hover-reveal

    private func showToolbar() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        guard !toolbarVisible else { return }
        withAnimation(.easeInOut(duration: 0.22)) { toolbarVisible = true }
        scheduleToolbarHide()
    }

    private func scheduleToolbarHide() {
        toolbarHideTask?.cancel()
        toolbarHideTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if NSEvent.pressedMouseButtons != 0 {
                    scheduleToolbarHide()
                    return
                }
                withAnimation(.easeInOut(duration: 0.22)) { toolbarVisible = false }
            }
        }
    }

    private func fitSize(in available: CGSize, ratio: CGFloat) -> (CGFloat, CGFloat) {
        available.width / available.height > ratio
            ? (available.height * ratio, available.height)
            : (available.width, available.width / ratio)
    }
}

// MARK: - ScreenshotFlashView

/// Thumbnail overlay shown in the corner after a screenshot is taken.
/// Tapping it opens the saved image in the default viewer.
private struct ScreenshotFlashView: View {

    let image: CGImage
    let url:   URL

    @State private var appeared = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFit()
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1 : 0.75, anchor: .bottomTrailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { appeared = true }
        }
        .padding(14)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .frame(width: 900, height: 760)
}
