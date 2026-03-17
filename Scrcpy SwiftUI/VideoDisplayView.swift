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
    var onFileDrop: (([URL]) -> Void)? = nil

    func makeNSView(context: Context) -> VideoNSView {
        let view = VideoNSView()
        view.setDisplayLayer(displayLayer)
        view.controlSocket = controlSocket
        view.onFileDrop = onFileDrop
        return view
    }

    func updateNSView(_ nsView: VideoNSView, context: Context) {
        nsView.setDisplayLayer(displayLayer)
        nsView.controlSocket = controlSocket
        nsView.onFileDrop = onFileDrop
    }
}

// MARK: - VideoNSView

final class VideoNSView: NSView {

    var controlSocket: ScrcpyControlSocket?
    var onFileDrop: (([URL]) -> Void)?
    private var currentLayer: AVSampleBufferDisplayLayer?
    private var dragOverlayView: NSView?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

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

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        showDragOverlay()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDragOverlay() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDragOverlay()
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return false }
        onFileDrop?(fileURLs)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) { hideDragOverlay() }

    private func showDragOverlay() {
        guard dragOverlayView == nil else { return }
        let overlay = NSView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        overlay.layer?.borderColor = NSColor.systemBlue.cgColor
        overlay.layer?.borderWidth = 3
        overlay.layer?.cornerRadius = 4
        addSubview(overlay)
        dragOverlayView = overlay
    }

    private func hideDragOverlay() {
        dragOverlayView?.removeFromSuperview()
        dragOverlayView = nil
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
        // Remap Cmd+key → Ctrl+key so Android shortcuts work naturally
        // (Android uses Ctrl for select-all, cut, copy, paste, undo, etc.)
        if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control) {
            var flags = e.modifierFlags
            flags.remove(.command)
            flags.insert(.control)
            controlSocket?.sendKeyDown(e.keyCode, modifierFlags: flags)
            return
        }
        if let chars = e.characters, !chars.isEmpty,
           !e.modifierFlags.contains(.command),
           !e.modifierFlags.contains(.control) {
            controlSocket?.sendText(chars)
        } else {
            controlSocket?.sendKeyDown(e.keyCode, modifierFlags: e.modifierFlags)
        }
    }
    override func keyUp(with e: NSEvent) {
        if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control) {
            var flags = e.modifierFlags
            flags.remove(.command)
            flags.insert(.control)
            controlSocket?.sendKeyUp(e.keyCode, modifierFlags: flags)
            return
        }
        controlSocket?.sendKeyUp(e.keyCode, modifierFlags: e.modifierFlags)
    }
    override func flagsChanged(with e: NSEvent) {
        // Modifier-only events; no action needed since we read flags on each key event
    }
}
