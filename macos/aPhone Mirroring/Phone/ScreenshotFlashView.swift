// ScreenshotFlashView.swift
// aPhone Mirroring
//
// Thumbnail flash overlay shown at bottom-trailing of the phone viewport after a screenshot.
// Springs in on appear; clicking opens the saved PNG in the default viewer via NSWorkspace. Shown
// in both main panel and pop-out window. Auto-dismissed by ScrcpyManager after 3.5 s.
//

import SwiftUI
import AppKit

// MARK: - ScreenshotFlashView

/// Thumbnail overlay shown in the corner after a screenshot is taken.
/// Tapping it opens the saved image in the default viewer.
struct ScreenshotFlashView: View {

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
