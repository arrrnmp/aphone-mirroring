//
//  ControlPanelView.swift
//  Scrcpy SwiftUI
//
//  Floating side panel with hardware control buttons.
//  Hosted in a borderless NSWindow managed by WindowManager.
//

import SwiftUI

struct ControlPanelView: View {
    let controlSocket: ScrcpyControlSocket

    var body: some View {
        VStack(spacing: 2) {
            panelButton("arrow.left",    tip: "Back")         { controlSocket.sendBackButton() }
            panelButton("house",         tip: "Home")         { controlSocket.sendHomeButton() }
            panelButton("square.stack",  tip: "Recents")      { controlSocket.sendAppSwitch() }
            panelSeparator
            panelButton("speaker.plus",  tip: "Volume Up")    { controlSocket.sendVolumeUp() }
            panelButton("speaker.minus", tip: "Volume Down")  { controlSocket.sendVolumeDown() }
            panelButton("speaker.slash", tip: "Mute")         { controlSocket.sendMute() }
            panelButton("power",         tip: "Power")        { controlSocket.sendPowerButton() }
            panelSeparator
            panelButton("rotate.right",  tip: "Rotate")       { controlSocket.sendRotateDevice() }
        }
        .padding(8)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var panelSeparator: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }

    private func panelButton(_ icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())  // hit area fills the full 44×44 box
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
