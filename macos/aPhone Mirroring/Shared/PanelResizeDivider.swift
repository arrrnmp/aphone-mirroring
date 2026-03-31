// PanelResizeDivider.swift
// aPhone Mirroring
//
// Thin 1pt drag handle shared by MessagesTabView and CallsTabView.
// An 8pt invisible hit target surrounds the visible line; dragging changes the
// bound width clamped to [minWidth, maxWidth]. Pushes NSCursor.resizeLeftRight
// on hover for native cursor feedback.
//

import SwiftUI
import AppKit

// MARK: - PanelResizeDivider

/// Thin 1pt line with an 8pt invisible hit target; drag to resize the left panel.
struct PanelResizeDivider: View {
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
