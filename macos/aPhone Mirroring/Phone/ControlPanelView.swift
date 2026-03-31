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
    /// Called on every button tap — used by the popout coordinator to reset the idle-fade timer.
    var onInteraction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            btn("arrow.left",    tip: "Back")         { controlSocket.sendBackButton() }
            btn("house",         tip: "Home")         { controlSocket.sendHomeButton() }
            btn("square.stack",  tip: "Recents")      { controlSocket.sendAppSwitch() }
            separator
            btn("speaker.plus",  tip: "Volume Up")    { controlSocket.sendVolumeUp() }
            btn("speaker.minus", tip: "Volume Down")  { controlSocket.sendVolumeDown() }
            btn("speaker.slash", tip: "Mute")         { controlSocket.sendMute() }
            btn("power",         tip: "Power")        { controlSocket.sendPowerButton() }
            separator
            btn("rotate.right",  tip: "Rotate")       { controlSocket.sendRotateDevice() }
        }
        .padding(8)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
    }

    private func btn(_ icon: String, tip: String, action: @escaping () -> Void) -> some View {
        ToolbarButton(icon: icon, help: tip, style: .panel) {
            action()
            onInteraction?()
        }
    }
}
