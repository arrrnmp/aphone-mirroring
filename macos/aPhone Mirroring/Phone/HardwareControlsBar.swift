// HardwareControlsBar.swift
// aPhone Mirroring
//
// Shared hardware control pill bar used by both PhonePanelView (inline) and PopoutView (fullscreen
// bottom bar). Three GlassEffectContainer groups: Volume (Up/Down/Mute), Navigation
// (Back/Home/Recents), System (Power/Rotate). Takes a single controlSocket parameter.
//

import SwiftUI

// MARK: - HardwareControlsBar

/// Shared hardware control bar used by both PhonePanelView's inline controls section
/// and PopoutView's fullscreen bottom bar.
struct HardwareControlsBar: View {
    let controlSocket: ScrcpyControlSocket

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    pill {
                        btn("speaker.plus",  "Vol +") { controlSocket.sendVolumeUp() }
                        btn("speaker.minus", "Vol −") { controlSocket.sendVolumeDown() }
                        btn("speaker.slash", "Mute")  { controlSocket.sendMute() }
                    }
                    pill {
                        btn("arrow.left",   "Back")    { controlSocket.sendBackButton() }
                        btn("house",         "Home")    { controlSocket.sendHomeButton() }
                        btn("square.stack",  "Recents") { controlSocket.sendAppSwitch() }
                    }
                    pill {
                        btn("power",        "Power")  { controlSocket.sendPowerButton() }
                        btn("rotate.right", "Rotate") { controlSocket.sendRotateDevice() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private func pill<C: View>(@ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func btn(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
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
