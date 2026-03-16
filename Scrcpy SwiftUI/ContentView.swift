//
//  ContentView.swift
//  Scrcpy SwiftUI
//

import SwiftUI
import AppKit

struct ContentView: View {

    @StateObject private var manager = ScrcpyManager()
    @StateObject private var appLog = AppLog.shared
    @State private var showLogPanel = false
    @State private var hideTask: Task<Void, Never>? = nil

    @Environment(WindowManager.self) private var windowManager
    @Namespace private var glassNS

    private var barExpanded: Bool { windowManager.barExpanded }

    var body: some View {
        ZStack {
            // ── Phone content — the full content-view area ────────────────
            // Top corners are always square: the title bar / accessory bar
            // above is the visual boundary. Bottom corners stay rounded.
            phoneSilhouette
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 40,
                        bottomTrailingRadius: 40,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )

            if showLogPanel {
                logPanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .ignoresSafeArea(edges: .all)
        .animation(.easeInOut(duration: 0.2), value: manager.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLogPanel)
        .task { await manager.refreshDevices() }
        .onChange(of: manager.videoStream.videoSize) { _, size in
            manager.controlSocket.updateVideoSize(
                width: Int(size.width),
                height: Int(size.height)
            )
        }
        .background(AspectRatioConfigurator(size: manager.videoStream.videoSize))
        // Mount the control-bar content into the titlebar accessory VC
        .background(
            ControlBarAccessoryInstaller {
                controlBarContent
            }
        )
        // Hover near the top of the content view to reveal the bar
        .onContinuousHover { phase in
            switch phase {
            case .active(let pt):
                // Trigger zone is the top 24 pt of the content view
                if pt.y < 24 { showBar() } else { scheduleHide() }
            case .ended:
                scheduleHide()
            }
        }
    }

    // MARK: - Bar show/hide

    private func showBar() {
        hideTask?.cancel()
        hideTask = nil
        if !barExpanded {
            windowManager.setBarExpanded(true)
        }
    }

    private func scheduleHide() {
        guard barExpanded else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            windowManager.setBarExpanded(false)
        }
    }

    // MARK: - Control bar (lives in the accessory VC, above the phone content)

    private var controlBarContent: some View {
        HStack(spacing: 0) {
            // ── Device label ──────────────────────────────────────────────
            deviceLabel
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.leading, 16)

            Spacer()

            // ── Android + utility buttons ─────────────────────────────────
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    androidButtons
                    if manager.state == .connected || !manager.availableDevices.isEmpty {
                        utilityDivider
                    }
                    utilityButtons
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
        .frame(maxWidth: .infinity)
        .preferredColorScheme(.dark)
        // Keep the bar visible for interaction — don't dismiss on hover over it
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showBar()
            case .ended:
                scheduleHide()
            }
        }
    }

    // MARK: - Bar sub-views

    private var deviceLabel: some View {
        Group {
            if manager.state == .connected, let name = manager.connectedDevice {
                Label(name, systemImage: "antenna.radiowaves.left.and.right")
            } else {
                Label("Android Mirror", systemImage: "smartphone")
            }
        }
    }

    @ViewBuilder
    private var androidButtons: some View {
        if manager.state == .connected {
            HStack(spacing: 2) {
                barButton("arrow.left",   help: "Back")    { manager.controlSocket.sendBackButton() }
                barButton("house",        help: "Home")    { manager.controlSocket.sendHomeButton() }
                barButton("square.stack", help: "Recents") { manager.controlSocket.sendAppSwitch() }
            }
            .glassEffect(.regular, in: Capsule())
            .glassEffectID("android", in: glassNS)
        }
    }

    private var utilityDivider: some View {
        Divider().frame(height: 18).opacity(0.4).padding(.horizontal, 2)
    }

    @ViewBuilder
    private var utilityButtons: some View {
        HStack(spacing: 2) {
            if manager.state != .connected && !manager.availableDevices.isEmpty {
                connectMenuButton
            }
            barButton("doc.text.magnifyingglass", help: "Logs") { showLogPanel.toggle() }
            if manager.state == .connected {
                barButton("stop.circle.fill", help: "Disconnect", tint: .red) {
                    Task { await manager.disconnect() }
                }
            }
        }
        .glassEffect(.regular, in: Capsule())
        .glassEffectID("utility", in: glassNS)
    }

    private var connectMenuButton: some View {
        Menu {
            ForEach(manager.availableDevices, id: \.self) { device in
                Button(device) { Task { await manager.connect(deviceSerial: device) } }
            }
            Divider()
            Button("Refresh") { Task { await manager.refreshDevices() } }
        } label: {
            Image(systemName: "plus.circle.fill")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("Connect")
    }

    private func barButton(
        _ icon: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let tint { Image(systemName: icon).foregroundStyle(tint) }
                else { Image(systemName: icon) }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Phone silhouette

    @ViewBuilder
    private var phoneSilhouette: some View {
        switch manager.state {
        case .connected:
            VideoDisplayView(
                displayLayer: manager.videoStream.displayLayer,
                controlSocket: manager.controlSocket
            )
        case .connecting:
            phoneShell { connectingView }
        case .disconnected:
            phoneShell { disconnectedContent }
        case .error(let msg):
            phoneShell { errorContent(message: msg) }
        }
    }

    private func phoneShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 40,
                    bottomTrailingRadius: 40,
                    topTrailingRadius: 0,
                    style: .continuous
                ))
            content()
        }
    }

    // MARK: - Log panel

    private var logPanelOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                HStack {
                    Label("Debug Log", systemImage: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Clear") { appLog.clear() }
                        .buttonStyle(.glass)
                    Button { showLogPanel = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.2)

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(appLog.entries) { entry in
                                LogEntryRow(entry: entry).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 240)
                    .onChange(of: appLog.entries.count) { _, _ in
                        if let last = appLog.entries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - State content

    private var connectingView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.primary.opacity(0.06))
                        .frame(width: 88, height: 88)
                    Image(systemName: "smartphone")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.primary.opacity(0.6))
                }
                VStack(spacing: 6) {
                    Text("Connecting")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Setting up mirroring…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.9)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disconnectedContent: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 32) {
                ZStack {
                    Circle()
                        .fill(.primary.opacity(0.06))
                        .frame(width: 100, height: 100)
                    Image(systemName: manager.availableDevices.isEmpty
                          ? "cable.connector.slash"
                          : "smartphone")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.primary.opacity(0.5))
                }
                VStack(spacing: 6) {
                    Text(manager.availableDevices.isEmpty ? "No Device Found" : "Choose a Device")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(manager.availableDevices.isEmpty
                         ? "Plug in your Android phone via USB\nand enable USB debugging."
                         : "Select a device below to start mirroring.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                if manager.availableDevices.isEmpty {
                    Button {
                        Task { await manager.refreshDevices() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: 180)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.glass)
                } else {
                    DevicePickerView(
                        devices: manager.availableDevices,
                        onConnect: { device in
                            Task { await manager.connect(deviceSerial: device) }
                        },
                        onRefresh: {
                            Task { await manager.refreshDevices() }
                        }
                    )
                    .frame(maxWidth: 280)
                }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.red.opacity(0.85))
                        .symbolRenderingMode(.hierarchical)
                }
                VStack(spacing: 8) {
                    Text("Connection Failed")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await manager.disconnect() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: 180)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DevicePickerView

private struct DevicePickerView: View {
    let devices: [String]
    let onConnect: (String) -> Void
    let onRefresh: () -> Void

    @Namespace private var pickNS

    var body: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 8) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { index, device in
                        DeviceRow(device: device, index: index) {
                            onConnect(device)
                        }
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .glassEffectID("device-\(index)", in: pickNS)
                    }
                }
            }

            Button(action: onRefresh) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                    Text("Refresh")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DeviceRow: View {
    let device: String
    let index: Int
    let action: () -> Void

    @State private var isHovered = false

    private var displayName: String {
        if let paren = device.firstIndex(of: "(") {
            return String(device[device.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return device
    }
    private var serialHint: String? {
        guard let open = device.firstIndex(of: "("),
              let close = device.firstIndex(of: ")") else { return nil }
        let serial = String(device[device.index(after: open)..<close])
        return serial.count > 12 ? String(serial.prefix(10)) + "…" : serial
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
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let serial = serialHint {
                        Text(serial)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Log entry row

private struct LogEntryRow: View {
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

// MARK: - Preview

#Preview {
    ContentView()
        .frame(width: 390, height: 844)
}
