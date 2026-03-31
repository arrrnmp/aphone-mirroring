//
//  BluetoothPairingManager.swift
//  aPhone Mirroring
//
//  Detects whether the connected Android device is paired with this Mac via
//  Classic Bluetooth (required for HFP call-audio routing), and initiates
//  pairing automatically.
//
//  Uses `system_profiler SPBluetoothDataType -json` to check pairing status
//  instead of the deprecated IOBluetooth framework (removed in macOS 26).
//  Pairing is initiated by making the Android device discoverable via ADB,
//  then opening macOS Bluetooth System Settings for the user to complete the
//  pairing dialog.
//

import Foundation
import AppKit

@MainActor
@Observable
final class BluetoothPairingManager {
    enum Status: Equatable {
        case idle
        case checking
        case notPaired(deviceName: String)
        case pairing(deviceName: String)
        case paired
        case unavailable(String)
    }

    var status: Status = .idle

    // Stored from checkAndPair so startPairing() can use them without params.
    private var storedAdbPath: String = ""
    private var storedSerial: String? = nil
    private var storedBtAddress: String = ""

    private var pollTask: Task<Void, Never>? = nil

    // MARK: - Public API

    func checkAndPair(adbPath: String, serial: String?) async {
        guard case .idle = status else { return }
        storedAdbPath = adbPath
        storedSerial = serial
        status = .checking

        // Read the phone's BT address via ADB.
        let rawAddr = await runAdb(["shell", "settings", "get", "secure", "bluetooth_address"])
        let addr = rawAddr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard addr.contains(":"), addr != "null", !addr.isEmpty else {
            status = .unavailable("Could not read Bluetooth address from device.")
            return
        }
        storedBtAddress = addr

        // Read the phone's friendly BT name via ADB.
        let rawName = await runAdb(["shell", "settings", "get", "global", "bluetooth_name"])
        let devName: String = {
            let n = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (n.isEmpty || n == "null") ? "Android Device" : n
        }()

        // Check macOS Bluetooth device list via system_profiler.
        let isPaired = await isAddressPairedOnMac(addr)
        status = isPaired ? .paired : .notPaired(deviceName: devName)
    }

    func startPairing() async {
        guard case .notPaired(let name) = status else { return }
        status = .pairing(deviceName: name)

        // Make the Android device discoverable for 120 s.
        await runAdb(["shell", "am", "start",
                      "-a", "android.bluetooth.adapter.action.REQUEST_DISCOVERABLE",
                      "--ei", "android.bluetooth.adapter.extra.DISCOVERABLE_DURATION", "120"])

        // Open macOS Bluetooth settings so the user can select the phone and pair.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)

        // Poll system_profiler every 2 s for up to 60 s, waiting for the user to
        // complete pairing in System Settings.
        let addrSnapshot = storedBtAddress
        let nameSnapshot = name
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let paired = await isAddressPairedOnMac(addrSnapshot)
                if paired {
                    self.status = .paired
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            if case .pairing = self.status {
                self.status = .notPaired(deviceName: nameSnapshot)
            }
        }
    }

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        status = .idle
    }

    // MARK: - Private

    /// Returns true if `addr` (lowercase, colon-separated) appears in the macOS
    /// Bluetooth device list reported by system_profiler.  Both "connected" and
    /// "not-connected" (i.e. previously paired) devices are covered because the
    /// address appears verbatim as the value of the `device_address` key in the
    /// JSON output, regardless of current connection state.
    private func isAddressPairedOnMac(_ addr: String) async -> Bool {
        let json = await runProcess("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        // Address appears as: "device_address" : "AA:BB:CC:DD:EE:FF"
        // Normalise both to uppercase for a case-insensitive match.
        let needle = addr.uppercased()
        return json.uppercased().contains(needle)
    }

    @discardableResult
    private func runAdb(_ args: [String]) async -> String {
        var fullArgs = storedSerial.map { ["-s", $0] } ?? []
        fullArgs += args
        return await runProcess(storedAdbPath, fullArgs)
    }

    @discardableResult
    private func runProcess(_ executablePath: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p    = Process()
            let pipe = Pipe()
            p.executableURL  = URL(fileURLWithPath: executablePath)
            p.arguments      = args
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
