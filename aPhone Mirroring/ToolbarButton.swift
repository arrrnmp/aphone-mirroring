//
//  ToolbarButton.swift
//  aPhone Mirroring
//
//  Unified button used in both the title-bar toolbar and the hardware-control panel.
//  Use .glass for 32×32 interactive glass-circle buttons (title bar / hover toolbar).
//  Use .panel for 44×44 plain buttons (ControlPanelView hardware controls).
//

import SwiftUI

struct ToolbarButton: View {

    enum Style {
        /// 32×32 glass-circle button for title bar and hover toolbars.
        case glass
        /// 44×44 plain button for the hardware-control side panel.
        case panel
    }

    let icon:   String
    let help:   String
    var tint:   Color? = nil
    var style:  Style  = .glass
    let action: () -> Void

    var body: some View {
        switch style {
        case .glass: glassButton
        case .panel: panelButton
        }
    }

    private var glassButton: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    private var panelButton: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
