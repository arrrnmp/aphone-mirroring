//
//  ScrcpyControlSocket.swift
//  Scrcpy SwiftUI
//
//  Sends input events to scrcpy-server over the control socket using
//  the scrcpy v3 binary protocol (all integers big-endian).
//
//  Message types:
//    0x00  INJECT_KEYCODE       14 bytes
//    0x01  INJECT_TEXT          5 + N bytes
//    0x02  INJECT_TOUCH_EVENT   32 bytes
//    0x03  INJECT_SCROLL_EVENT  21 bytes
//    0x04  BACK_OR_SCREEN_ON    2 bytes
//    0x0A  SET_DISPLAY_POWER    2 bytes
//

import Foundation
import AppKit
import Network
import Combine

// MARK: - ScrcpyControlSocket

@MainActor
final class ScrcpyControlSocket: ObservableObject {

    private var connection: NWConnection?
    // Must match the current video frame dimensions (server validates these)
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    // MARK: - Lifecycle

    func start(connection: NWConnection, videoWidth: Int, videoHeight: Int) async {
        self.connection = connection
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
    }

    func updateVideoSize(width: Int, height: Int) {
        videoWidth = width
        videoHeight = height
    }

    func stop() async {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Mouse / Touch

    /// Maps a view-local NSPoint to device pixel coords and sends a touch event.
    func sendMouseDown(_ point: NSPoint, in viewSize: CGSize, button: MouseButton = .left) {
        let (x, y) = mapPoint(point, viewSize: viewSize)
        sendTouchEvent(action: .down, pointerId: button.pointerId,
                       x: x, y: y, pressure: 0xFFFF,
                       actionButton: button.androidButton, buttons: button.androidButton)
    }

    func sendMouseUp(_ point: NSPoint, in viewSize: CGSize, button: MouseButton = .left) {
        let (x, y) = mapPoint(point, viewSize: viewSize)
        sendTouchEvent(action: .up, pointerId: button.pointerId,
                       x: x, y: y, pressure: 0,
                       actionButton: button.androidButton, buttons: 0)
    }

    func sendMouseMove(_ point: NSPoint, in viewSize: CGSize, buttonsDown: Int) {
        let (x, y) = mapPoint(point, viewSize: viewSize)
        let isDown = buttonsDown & 1 != 0
        sendTouchEvent(action: .move, pointerId: MouseButton.left.pointerId,
                       x: x, y: y, pressure: isDown ? 0xFFFF : 0,
                       actionButton: 0, buttons: isDown ? MouseButton.left.androidButton : 0)
    }

    func sendScroll(_ point: NSPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat) {
        let (x, y) = mapPoint(point, viewSize: viewSize)
        // scrcpy scroll: 1.15 fixed-point: clamp to [-1,1] then multiply by 0x7FFF
        let hScroll = Int16(clamping: Int((-deltaX / 3.0).clamped(to: -1...1) * 0x7FFF))
        let vScroll = Int16(clamping: Int((deltaY / 3.0).clamped(to: -1...1) * 0x7FFF))

        var msg = Data(capacity: 21)
        msg.append(0x03)
        msg.appendBigEndian32(UInt32(bitPattern: x))
        msg.appendBigEndian32(UInt32(bitPattern: y))
        msg.appendBigEndian16(UInt16(videoWidth))
        msg.appendBigEndian16(UInt16(videoHeight))
        msg.appendBigEndian16(UInt16(bitPattern: hScroll))
        msg.appendBigEndian16(UInt16(bitPattern: vScroll))
        msg.appendBigEndian32(0) // buttons
        send(msg)
    }

    // MARK: - Keyboard

    func sendKeyDown(_ keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let akeycode = macToAndroidKeycode(keyCode)
        guard akeycode != 0 else { return }
        sendKeycode(action: 0, keycode: akeycode, metaState: androidMetaState(modifierFlags))
    }

    func sendKeyUp(_ keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let akeycode = macToAndroidKeycode(keyCode)
        guard akeycode != 0 else { return }
        sendKeycode(action: 1, keycode: akeycode, metaState: androidMetaState(modifierFlags))
    }

    func sendText(_ text: String) {
        guard let utf8 = text.data(using: .utf8), !utf8.isEmpty else { return }
        var msg = Data(capacity: 5 + utf8.count)
        msg.append(0x01)
        msg.appendBigEndian32(UInt32(utf8.count))
        msg.append(utf8)
        send(msg)
    }

    // MARK: - Device controls

    func sendBackButton() {
        send(Data([0x04, 0x01])) // DOWN
        send(Data([0x04, 0x00])) // UP
    }

    func sendHomeButton() {
        sendKeycode(action: 0, keycode: 3, metaState: 0)  // AKEYCODE_HOME down
        sendKeycode(action: 1, keycode: 3, metaState: 0)  // up
    }

    func sendAppSwitch() {
        sendKeycode(action: 0, keycode: 187, metaState: 0) // AKEYCODE_APP_SWITCH
        sendKeycode(action: 1, keycode: 187, metaState: 0)
    }

    // MARK: - Private serialisation

    private enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    private func sendTouchEvent(action: TouchAction, pointerId: Int64,
                                 x: Int32, y: Int32,
                                 pressure: UInt16,
                                 actionButton: Int32, buttons: Int32) {
        var msg = Data(capacity: 32)
        msg.append(0x02)                                         // type
        msg.append(action.rawValue)                              // action
        msg.appendBigEndian64(UInt64(bitPattern: pointerId))     // pointer id
        msg.appendBigEndian32(UInt32(bitPattern: x))             // x
        msg.appendBigEndian32(UInt32(bitPattern: y))             // y
        msg.appendBigEndian16(UInt16(videoWidth))                // screen width
        msg.appendBigEndian16(UInt16(videoHeight))               // screen height
        msg.appendBigEndian16(pressure)                          // pressure
        msg.appendBigEndian32(UInt32(bitPattern: actionButton))  // action button
        msg.appendBigEndian32(UInt32(bitPattern: buttons))       // buttons down
        send(msg)
    }

    private func sendKeycode(action: UInt8, keycode: Int32, metaState: Int32) {
        var msg = Data(capacity: 14)
        msg.append(0x00)
        msg.append(action)
        msg.appendBigEndian32(UInt32(bitPattern: keycode))
        msg.appendBigEndian32(0) // repeat count
        msg.appendBigEndian32(UInt32(bitPattern: metaState))
        send(msg)
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: - Coordinate mapping

    private func mapPoint(_ point: NSPoint, viewSize: CGSize) -> (x: Int32, y: Int32) {
        guard videoWidth > 0, videoHeight > 0 else { return (0, 0) }
        // NSView has bottom-left origin; Android has top-left
        let nx = (point.x / viewSize.width).clamped(to: 0...1)
        let ny = (1.0 - point.y / viewSize.height).clamped(to: 0...1)
        return (Int32(nx * Double(videoWidth)), Int32(ny * Double(videoHeight)))
    }

    // MARK: - Meta state

    private func androidMetaState(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var meta: Int32 = 0
        if flags.contains(.shift)   { meta |= 0x00000001 } // META_SHIFT_ON
        if flags.contains(.option)  { meta |= 0x00000002 } // META_ALT_ON
        if flags.contains(.control) { meta |= 0x00001000 } // META_CTRL_ON
        if flags.contains(.command) { meta |= 0x00010000 } // META_META_ON
        return meta
    }

    // MARK: - macOS → Android keycode table

    private func macToAndroidKeycode(_ kVK: UInt16) -> Int32 {
        switch kVK {
        case 0x00: return 29  // A
        case 0x0B: return 30  // B
        case 0x08: return 31  // C
        case 0x02: return 32  // D
        case 0x0E: return 33  // E
        case 0x03: return 34  // F
        case 0x05: return 35  // G
        case 0x04: return 36  // H
        case 0x22: return 37  // I
        case 0x26: return 38  // J
        case 0x28: return 39  // K
        case 0x25: return 40  // L
        case 0x2E: return 41  // M
        case 0x2D: return 42  // N
        case 0x1F: return 43  // O
        case 0x23: return 44  // P
        case 0x0C: return 45  // Q
        case 0x0F: return 46  // R
        case 0x01: return 47  // S
        case 0x11: return 48  // T
        case 0x20: return 49  // U
        case 0x09: return 50  // V
        case 0x0D: return 51  // W
        case 0x07: return 52  // X
        case 0x10: return 53  // Y
        case 0x06: return 54  // Z
        case 0x1D: return 7   // 0
        case 0x12: return 8   // 1
        case 0x13: return 9   // 2
        case 0x14: return 10  // 3
        case 0x15: return 11  // 4
        case 0x17: return 12  // 5
        case 0x16: return 13  // 6
        case 0x1A: return 14  // 7
        case 0x1C: return 15  // 8
        case 0x19: return 16  // 9
        case 0x24: return 66  // Return
        case 0x30: return 61  // Tab
        case 0x31: return 62  // Space
        case 0x33: return 67  // Backspace (Delete)
        case 0x35: return 111 // Escape
        case 0x75: return 112 // Forward Delete
        case 0x7B: return 21  // Left
        case 0x7C: return 22  // Right
        case 0x7E: return 19  // Up
        case 0x7D: return 20  // Down
        case 0x73: return 122 // Home
        case 0x77: return 123 // End
        case 0x74: return 92  // Page Up
        case 0x79: return 93  // Page Down
        case 0x7A: return 131 // F1
        case 0x78: return 132 // F2
        case 0x63: return 133 // F3
        case 0x76: return 134 // F4
        case 0x60: return 135 // F5
        case 0x61: return 136 // F6
        case 0x62: return 137 // F7
        case 0x64: return 138 // F8
        case 0x65: return 139 // F9
        case 0x6D: return 140 // F10
        case 0x67: return 141 // F11
        case 0x6F: return 142 // F12
        case 0x27: return 75  // ' (apostrophe → KEYCODE_APOSTROPHE)
        case 0x2B: return 55  // , (comma)
        case 0x2F: return 56  // . (period)
        case 0x2C: return 76  // / (slash)
        case 0x29: return 74  // ; (semicolon)
        case 0x18: return 70  // = (equals)
        case 0x1B: return 69  // - (minus)
        case 0x21: return 71  // [ (left bracket)
        case 0x1E: return 72  // ] (right bracket)
        case 0x2A: return 73  // \ (backslash)
        case 0x32: return 68  // ` (grave)
        default:   return 0
        }
    }
}

// MARK: - MouseButton

enum MouseButton {
    case left, right, middle

    var pointerId: Int64 {
        switch self {
        case .left:   return -1  // POINTER_ID_MOUSE
        case .right:  return -1
        case .middle: return -1
        }
    }

    var androidButton: Int32 {
        switch self {
        case .left:   return 1  // AMOTION_EVENT_BUTTON_PRIMARY
        case .right:  return 2  // AMOTION_EVENT_BUTTON_SECONDARY
        case .middle: return 4  // AMOTION_EVENT_BUTTON_TERTIARY
        }
    }
}

// MARK: - Data serialisation helpers

extension Data {
    mutating func appendBigEndian16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xFF))
    }
    mutating func appendBigEndian32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func appendBigEndian64(_ v: UInt64) {
        appendBigEndian32(UInt32(v >> 32))
        appendBigEndian32(UInt32(v & 0xFFFFFFFF))
    }
}

// MARK: - Numeric helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
