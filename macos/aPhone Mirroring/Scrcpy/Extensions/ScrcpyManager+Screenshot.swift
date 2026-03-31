//
//  ScrcpyManager+Screenshot.swift
//  aPhone Mirroring
//
//  Screen capture from the live video stream.
//
//  No command is sent to the Android device — the frame is captured from
//  ScrcpyVideoStream.latestDecodedBuffer, which is kept current on every
//  frame by a persistent VTDecompressionSession running in the background.
//
//  Output: PNG on the Desktop, shutter sound, ScreenshotFlash thumbnail overlay.
//

import AppKit
import ImageIO
import SwiftUI

extension ScrcpyManager {

    // MARK: - Screenshot

    /// Captures the currently displayed video frame and saves it to the Desktop as a PNG.
    /// Plays a shutter sound, shows a thumbnail flash overlay, and auto-dismisses after 3.5 s.
    func takeScreenshot() {
        guard let image = videoStream.captureCurrentFrame() else {
            log("Screenshot: no decoded frame available yet", level: .warn)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "aPhone Screenshot \(formatter.string(from: Date())).png"
        let desktop  = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let fileURL  = desktop.appendingPathComponent(filename)

        guard let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else {
            log("Screenshot: could not create destination at \(fileURL.path)", level: .error)
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            log("Screenshot: failed to write PNG", level: .error)
            return
        }

        log("Screenshot saved: \(filename)", level: .ok)
        let shutterPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: shutterPath, byReference: true) ?? NSSound(named: "Pop"))?.play()

        let flash = ScreenshotFlash(image: image, url: fileURL)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            screenshotFlash = flash
        }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if screenshotFlash?.id == flash.id {
                withAnimation(.easeOut(duration: 0.25)) { screenshotFlash = nil }
            }
        }
    }
}
