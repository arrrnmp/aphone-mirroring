// PopoutView.swift
// aPhone Mirroring
//
// Full-screen phone view inside the pop-out NSWindow. Hosts VideoDisplayView, the hover-reveal
// toolbar (ToolbarHoverArea + traffic lights), the fullscreen HardwareControlsBar, and the
// ScreenshotFlashView overlay. Observes manager.videoStream.videoSize directly for live fitSize
// computation.
//

import SwiftUI
import AppKit

// MARK: - PopoutView

/// Full-screen phone viewport hosted in a separate NSWindow when the user pops out the phone.
/// Utility buttons (retreat, logs, pin, disconnect) hover-reveal from the top edge.
/// The hardware-control sidebar (ControlPanelView) is a separate NSWindow managed by PhonePanelView.
struct PopoutView: View {

    let manager:     ScrcpyManager
    @ObservedObject var coordinator: PopoutCoordinator
    @Environment(WindowManager.self) private var windowManager
    let onRetreat:       () -> Void
    /// Called when the toolbar is shown/hidden so the window can grow/shrink upward.
    let onToolbarExpand: (Bool) -> Void

    @State private var showLogPanel     = false
    @State private var toolbarVisible   = false
    @State private var toolbarHideTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Hover-reveal title bar ─────────────────────────────────────────
            // Dark pill that sits above the video (Simulator-style).
            // Window grows upward to accommodate it; phone viewport never shifts.
            if toolbarVisible {
                ZStack {
                    // Dark pill — same width as the video, 6 pt gap below it.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(white: 0.15))
                        .padding(.bottom, 6)

                    WindowDragArea()

                    HStack(spacing: 0) {
                        // Traffic-light clearance
                        Color.clear.frame(width: 76)

                        // Device name
                        Text(manager.connectedDevice ?? "Phone")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 8)

                        // Plain icon buttons — no glass, no circles
                        HStack(spacing: 0) {
                            titleBtn("pip.exit", "Restore to Main Window") { onRetreat() }
                            titleBtn("doc.text.magnifyingglass", "Debug Logs") { showLogPanel.toggle() }
                            titleBtn(coordinator.isPinned ? "pin.fill" : "pin",
                                     coordinator.isPinned ? "Unpin" : "Always on Top",
                                     tint: coordinator.isPinned ? .yellow : nil) {
                                coordinator.togglePin()
                            }
                            titleBtn(manager.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                     manager.audioEnabled ? "Disable Audio" : "Enable Audio",
                                     tint: manager.audioEnabled ? nil : .orange) {
                                manager.audioEnabled.toggle()
                            }
                            titleBtn("camera", "Screenshot") { manager.takeScreenshot() }
                            titleBtn("stop.circle.fill", "Disconnect", tint: .red) {
                                Task { await manager.disconnect() }
                            }
                        }
                        .padding(.trailing, 10)
                    }
                }
                .frame(height: controlBarHeight)
                .transition(.move(edge: .top).combined(with: .opacity))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            // ── Fullscreen controls bar ────────────────────────────────────────
            // Only shown in landscape fullscreen. Lives in the VStack so the video
            // never overlaps it — the GeometryReader shrinks to give it room.
            if coordinator.isFullscreen {
                fullscreenControlsBar
                    .padding(.vertical, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
        .animation(.smooth(duration: 0.3), value: coordinator.isFullscreen)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLogPanel)
        .onChange(of: toolbarVisible) { _, expanded in onToolbarExpand(expanded) }
        .preferredColorScheme(.dark)
    }

    // MARK: Title bar button

    private func titleBtn(_ icon: String, _ tip: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
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

    // MARK: Fullscreen controls bar

    private var fullscreenControlsBar: some View {
        HardwareControlsBar(controlSocket: manager.controlSocket)
    }
}
