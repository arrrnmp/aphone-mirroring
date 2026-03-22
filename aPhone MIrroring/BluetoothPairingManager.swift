//
//  BluetoothPairingManager.swift
//  aPhone Mirroring
//
//  Detects whether the connected Android device is paired with this Mac via
//  Classic Bluetooth (required for HFP call-audio routing), and initiates
//  pairing automatically using IOBluetooth when it is not.
//
//  Flow:
//    1. After USB connection: checkAndPair(adbPath:serial:) is called.
//    2. Phone's BT address is read from ADB.
//    3. IOBluetoothDevice.isPaired() decides the status.
//    4. If not paired: UI shows a banner; user taps "Pair Now".
//    5. startPairing() makes the phone discoverable via ADB, then calls
//       requestAuthentication() which shows the macOS pairing dialog.
//    6. A background task polls isPaired() every 2 s (60 s timeout).
//
//  Threading notes:
//    • All IOBluetooth calls are dispatched explicitly to DispatchQueue.main
//      to satisfy the framework's main-thread requirement.
//    • ADB processes use terminationHandler (non-blocking) instead of
//      waitUntilExit() to avoid blocking GCD threads that Swift's cooperative
//      executor may share on Apple Silicon.
//

import Foundation
import Combine
import IOBluetooth

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

    private var btDevice: IOBluetoothDevice?
    private var pollTask: Task<Void, Never>?
    private var storedAdbPath: String = ""
    private var storedSerial: String? = nil

    // MARK: - Public API

    func checkAndPair(adbPath: String, serial: String?) async {
        storedAdbPath = adbPath
        storedSerial  = serial

        guard case .idle = status else { return }
        status = .checking

        // 1. Read BT address from the phone (two ADB calls, both non-blocking)
        let rawAddr = await shell(adbPath, serial, ["shell", "settings", "get", "secure", "bluetooth_address"])
        let addr    = rawAddr.lowercased()
        guard addr.contains(":"), addr != "null", addr != "" else {
            status = .unavailable("Could not read Bluetooth address from device.")
            return
        }

        let rawName = await shell(adbPath, serial, ["shell", "settings", "get", "global", "bluetooth_name"])
        let devName = (rawName.isEmpty || rawName == "null") ? "Android Device" : rawName

        // 2. IOBluetooth lookup — must be on the main thread
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
        btDevice = dev

        if paired.1 {
            status = .paired
            DispatchQueue.main.async { dev.openConnection(nil) }
        } else {
            status = .notPaired(deviceName: devName)
        }
    }

    func startPairing() async {
        guard let dev = btDevice,
              case .notPaired(let name) = status else { return }

        status = .pairing(deviceName: name)

        // Make the phone discoverable for 120 s
        var discArgs = ["shell", "am", "start",
                        "-a", "android.bluetooth.adapter.action.REQUEST_DISCOVERABLE",
                        "--ei", "android.bluetooth.adapter.extra.DISCOVERABLE_DURATION", "120"]
        if let s = storedSerial { discArgs = ["-s", s] + discArgs }
        await shell(storedAdbPath, storedSerial, discArgs)

        // Show the macOS pairing dialog — must be on the main thread
        DispatchQueue.main.async { dev.requestAuthentication() }

        // Poll isPaired() every 2 s, 60 s total timeout
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let isPaired = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    DispatchQueue.main.async { cont.resume(returning: dev.isPaired()) }
                }
                if isPaired {
                    self.status = .paired
                    DispatchQueue.main.async { dev.openConnection(nil) }
                    return
                }
            }
            if case .pairing(let n) = self?.status {
                self?.status = .notPaired(deviceName: n)
            }
        }
    }

    func reset() {
        pollTask?.cancel()
        pollTask      = nil
        btDevice      = nil
        status        = .idle
    }

    // MARK: - ADB helper (non-blocking — uses terminationHandler, not waitUntilExit)

    @discardableResult
    private func shell(_ adbPath: String, _ serial: String?, _ args: [String]) async -> String {
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
