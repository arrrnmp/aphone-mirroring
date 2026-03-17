//
//  VideoDisplayView.swift
//  Scrcpy SwiftUI
//
//  NSViewRepresentable that hosts AVSampleBufferDisplayLayer and
//  forwards mouse/keyboard events to ScrcpyControlSocket.
//

import SwiftUI
import AVFoundation
import AppKit

// MARK: - VideoDisplayView

struct VideoDisplayView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let controlSocket: ScrcpyControlSocket

    func makeNSView(context: Context) -> VideoNSView {
        let view = VideoNSView()
        view.setDisplayLayer(displayLayer)
        view.controlSocket = controlSocket
        return view
    }

    func updateNSView(_ nsView: VideoNSView, context: Context) {
        nsView.setDisplayLayer(displayLayer)
        nsView.controlSocket = controlSocket
    }
}

// MARK: - VideoNSView

final class VideoNSView: NSView {

    var controlSocket: ScrcpyControlSocket?
    private var currentLayer: AVSampleBufferDisplayLayer?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        guard currentLayer !== layer else { return }
        currentLayer?.removeFromSuperlayer()
        currentLayer = layer
        wantsLayer = true
        self.layer?.backgroundColor = CGColor.clear
        self.layer?.addSublayer(layer)
        layer.frame = bounds
        layer.videoGravity = .resize
        layer.backgroundColor = CGColor.black
    }

    override func layout() {
        super.layout()
        currentLayer?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Tracking area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Mouse

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseDown(pt, in: bounds.size, button: .left)
    }
    override func mouseUp(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseUp(pt, in: bounds.size, button: .left)
    }
    override func mouseDragged(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseMove(pt, in: bounds.size, buttonsDown: 1)
    }
    override func mouseMoved(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseMove(pt, in: bounds.size, buttonsDown: 0)
    }
    override func rightMouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseDown(pt, in: bounds.size, button: .right)
    }
    override func rightMouseUp(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendMouseUp(pt, in: bounds.size, button: .right)
    }
    override func scrollWheel(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        controlSocket?.sendScroll(pt, in: bounds.size,
                                   deltaX: e.scrollingDeltaX,
                                   deltaY: e.scrollingDeltaY)
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) {
        if let chars = e.characters, !chars.isEmpty,
           !e.modifierFlags.contains(.command),
           !e.modifierFlags.contains(.control) {
            controlSocket?.sendText(chars)
        } else {
            controlSocket?.sendKeyDown(e.keyCode, modifierFlags: e.modifierFlags)
        }
    }
    override func keyUp(with e: NSEvent) {
        controlSocket?.sendKeyUp(e.keyCode, modifierFlags: e.modifierFlags)
    }
    override func flagsChanged(with e: NSEvent) {
        // Modifier-only events; no action needed since we read flags on each key event
    }
}
