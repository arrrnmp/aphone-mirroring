//
//  CallWindowController.swift
//  aPhone Mirroring
//
//  Manages the floating call window shown during an active phone call.
//  Appears when DataBridgeClient.activeCall becomes non-nil.
//

import SwiftUI
import AppKit

// MARK: - CallWindowController

@MainActor
final class CallWindowController {

    static let shared = CallWindowController()
    private init() {}

    private weak var window: NSWindow?
    private var hostingView: NSHostingView<CallView>?

    func show(call: BridgeCallState, bridge: DataBridgeClient) {
        if let win = window, win.isVisible {
            // Update existing window with new call state
            hostingView?.rootView = CallView(call: call, bridge: bridge)
            return
        }

        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 230

        let view = CallView(call: call, bridge: bridge)
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true

        // Position top-right corner, respecting menu bar and any screen margin
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let margin: CGFloat = 12
            win.setFrameOrigin(NSPoint(
                x: vf.maxX - windowWidth - margin,
                y: vf.maxY - windowHeight - margin
            ))
        }

        win.makeKeyAndOrderFront(nil)
        window = win
    }

    func dismiss() {
        window?.close()
        window = nil
        hostingView = nil
    }
}

// MARK: - CallView

struct CallView: View {

    let call: BridgeCallState
    @ObservedObject var bridge: DataBridgeClient

    @State private var isMuted = false
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var showHFPHelp = false

    var body: some View {
        VStack(spacing: 16) {
            // Contact info
            VStack(spacing: 4) {
                Text(call.contactName ?? (call.number.isEmpty ? "Unknown" : call.number))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)

                if let name = call.contactName, !name.isEmpty, !call.number.isEmpty {
                    Text(call.number)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(call.state == .active ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if call.state == .active, elapsedSeconds > 0 {
                        Text("· \(formattedDuration)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Action buttons — Liquid Glass
            GlassEffectContainer(spacing: 20) {
                HStack(spacing: 20) {
                    callButton(
                        icon: isMuted ? "mic.slash.fill" : "mic.fill",
                        label: isMuted ? "Unmute" : "Mute",
                        tint: isMuted ? .orange : nil
                    ) {
                        isMuted.toggle()
                        bridge.sendCallAction(isMuted ? "mute" : "unmute")
                    }
                    callButton(icon: "phone.down.fill", label: "End", tint: .red) {
                        bridge.sendCallAction("hangup")
                    }
                    callButton(icon: "laptopcomputer", label: "Mac Audio") {
                        bridge.sendCallAction("use_mac_audio")
                    }
                    callButton(icon: "iphone", label: "Phone Audio") {
                        bridge.sendCallAction("use_phone_audio")
                    }
                }
            }

            // Bottom notice — HFP setup help or default BT pairing hint
            if showHFPHelp {
                VStack(spacing: 4) {
                    Text("Enable 'Call Audio' for your Mac")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("Phone Bluetooth Settings → tap your Mac → turn on Call Audio")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        bridge.openBluetoothSettingsOnPhone()
                        showHFPHelp = false
                    } label: {
                        Label("Open Phone Bluetooth Settings", systemImage: "bluetooth")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .multilineTextAlignment(.center)
            } else {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                } label: {
                    Label("Pair Mac via Bluetooth for audio routing",
                          systemImage: "bluetooth")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Open Bluetooth System Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 340, height: 230)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { startTimer() }
        .onDisappear { timerTask?.cancel() }
        .onChange(of: call.state) { _, state in
            timerTask?.cancel()
            elapsedSeconds = 0
            if state == .active { startTimer() }
        }
        .onChange(of: bridge.callAudioError) { _, error in
            if error == "hfp_unavailable" { showHFPHelp = true }
        }
    }

    private var statusText: String {
        switch call.state {
        case .ringing: "Incoming Call"
        case .active:  "Active Call"
        case .idle:    "Ended"
        }
    }

    private var formattedDuration: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        guard call.state == .active else { return }
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run { elapsedSeconds += 1 }
            }
        }
    }

    private func callButton(icon: String, label: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint ?? .primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
