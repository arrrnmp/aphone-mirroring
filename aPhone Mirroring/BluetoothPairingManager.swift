//
//  BluetoothPairingManager.swift
//  aPhone Mirroring
//
//  Detects whether the connected Android device is paired with this Mac via
//  Classic Bluetooth (required for HFP call-audio routing), and initiates
//  pairing automatically using IOBluetooth when it is not.
//
//  TEMPORARILY DISABLED: IOBluetooth calls crash the app.
//  The original implementation is preserved below in #if false.
//

import Foundation
import Combine

// Stub — returns .idle immediately so all callers compile and run without crashing.
@MainActor
final class BluetoothPairingManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case notPaired(deviceName: String)
        case pairing(deviceName: String)
        case paired
        case unavailable(String)
    }

    @Published var status: Status = .idle

    func checkAndPair(adbPath: String, serial: String?) async {}
    func startPairing() async {}
    func reset() { status = .idle }
}

// MARK: - Original IOBluetooth implementation (disabled)

#if false

import IOBluetooth

extension BluetoothPairingManager {

    private var btDevice: IOBluetoothDevice? { nil }

    func _checkAndPair(adbPath: String, serial: String?) async {
        guard case .idle = status else { return }
        status = .checking

        let rawAddr = await _shell(adbPath, serial, ["shell", "settings", "get", "secure", "bluetooth_address"])
        let addr    = rawAddr.lowercased()
        guard addr.contains(":"), addr != "null", addr != "" else {
            status = .unavailable("Could not read Bluetooth address from device.")
            return
        }

        let rawName = await _shell(adbPath, serial, ["shell", "settings", "get", "global", "bluetooth_name"])
        let devName = (rawName.isEmpty || rawName == "null") ? "Android Device" : rawName

        let paired = await withCheckedContinuation { (cont: CheckedContinuation<(IOBluetoothDevice?, Bool), Never>) in
            DispatchQueue.main.async {
                let dev = IOBluetoothDevice(addressString: addr)
                cont.resume(returning: (dev, dev?.isPaired() ?? false))
            }
        }

        guard let dev = paired.0 else {
            status = .notPaired(deviceName: devName)
            return
        }

        if paired.1 {
            status = .paired
            DispatchQueue.main.async { dev.openConnection(nil) }
        } else {
            status = .notPaired(deviceName: devName)
        }
    }

    func _startPairing(adbPath: String, serial: String?) async {
        guard case .notPaired(let name) = status else { return }
        status = .pairing(deviceName: name)

        var discArgs = ["shell", "am", "start",
                        "-a", "android.bluetooth.adapter.action.REQUEST_DISCOVERABLE",
                        "--ei", "android.bluetooth.adapter.extra.DISCOVERABLE_DURATION", "120"]
        if let s = serial { discArgs = ["-s", s] + discArgs }
        await _shell(adbPath, serial, discArgs)

        // requestAuthentication() triggers the macOS pairing dialog
        // DispatchQueue.main.async { dev.requestAuthentication() }

        // Poll isPaired() every 2 s, 60 s total
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                // let isPaired = dev.isPaired()
                // if isPaired { self.status = .paired; dev.openConnection(nil); return }
            }
            if case .pairing(let n) = self?.status {
                self?.status = .notPaired(deviceName: n)
            }
        }
    }

    @discardableResult
    private func _shell(_ adbPath: String, _ serial: String?, _ args: [String]) async -> String {
        var full = serial.map { ["-s", $0] } ?? []
        full += args
        return await withCheckedContinuation { cont in
            let p    = Process()
            let pipe = Pipe()
            p.executableURL  = URL(fileURLWithPath: adbPath)
            p.arguments      = full
            p.standardOutput = pipe
            p.standardError  = Pipe()
            p.terminationHandler = { _ in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                cont.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do    { try p.run() }
            catch { cont.resume(returning: "") }
        }
    }
}

#endif
