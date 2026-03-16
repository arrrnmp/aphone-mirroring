//
//  ScrcpyManager.swift
//  Scrcpy SwiftUI
//

import Foundation
import AppKit
import Combine
import Network

// MARK: - Connection State

enum ScrcpyState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - ScrcpyManager

@MainActor
final class ScrcpyManager: ObservableObject {

    @Published var state: ScrcpyState = .disconnected
    @Published var connectedDevice: String? = nil  // display name from handshake
    @Published var availableDevices: [String] = []  // display strings "Model (serial)"

    // Serial of the currently connected device, used for disconnect detection
    private var connectedSerial: String? = nil

    let videoStream = ScrcpyVideoStream()
    let controlSocket = ScrcpyControlSocket()

    private let adbPath: String = {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/opt/homebrew/bin/adb"  // fallback, will fail with a clear error
    }()

    private var serverJarURL: URL? {
        let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil)
        log("Server JAR lookup: \(url?.path ?? "NOT FOUND in bundle")",
            level: url == nil ? .error : .debug)
        return url
    }

    private var serverProcess: Process?
    private var tcpListener: NWListener?
    private var devicePollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    private let listenPort: UInt16 = 27183
    private var scid: UInt32 = 0

    init() {
        log("ScrcpyManager init — adb: \(adbPath)", level: .debug)
        log("adb exists: \(FileManager.default.fileExists(atPath: adbPath))", level: .debug)
        startDevicePolling()
    }

    // MARK: - Device Discovery

    private func startDevicePolling() {
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshDevices() async {
        let raw = await adb(["devices", "-l"])
        log("adb devices output:\n\(raw.trimmingCharacters(in: .whitespacesAndNewlines))", level: .debug)
        let parsed = parseADBDevices(raw)
        availableDevices = parsed
        log("Parsed devices: \(parsed.isEmpty ? "(none)" : parsed.joined(separator: ", "))",
            level: parsed.isEmpty ? .warn : .ok)
        // Disconnect only if the connected serial is no longer in the adb device list
        if let serial = connectedSerial {
            let serials = parsed.compactMap { extractSerial(from: $0) }
            if !serials.contains(serial) {
                log("Connected device \(serial) disappeared — disconnecting", level: .warn)
                await disconnect()
            }
        }
    }

    private func parseADBDevices(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .filter { line in
                // Match lines where the state field is exactly "device"
                // adb devices -l uses spaces (not tabs) between serial and state
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count >= 2 && parts[1] == "device"
            }
            .compactMap { line -> String? in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let serial = parts.first else { return nil }
                let model = parts.first(where: { $0.hasPrefix("model:") })
                    .map { $0.replacingOccurrences(of: "model:", with: "")
                              .replacingOccurrences(of: "_", with: " ") }
                return model.map { "\($0) (\(serial))" } ?? serial
            }
    }

    // MARK: - Connect

    func connect(deviceSerial: String? = nil) async {
        guard state == .disconnected else {
            log("connect() called but state is \(state) — ignoring", level: .warn)
            return
        }
        log("──── Starting connection to: \(deviceSerial ?? "first available device") ────")
        state = .connecting

        let serial = extractSerial(from: deviceSerial)
        log("Using serial: \(serial ?? "(auto)")")

        connectTask = Task {
            do {
                try await performConnect(serial: serial)
            } catch {
                log("Connection failed: \(error.localizedDescription)", level: .error)
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func performConnect(serial: String?) async throws {
        let serialArgs = serial.map { ["-s", $0] } ?? []

        // Step 1: Verify ADB is reachable
        log("Step 1: Checking adb…")
        let adbVersion = await adb(["version"])
        log("adb version: \(adbVersion.components(separatedBy: "\n").first ?? adbVersion)", level: .debug)

        // Step 2: Check server JAR
        log("Step 2: Locating scrcpy-server JAR in bundle…")
        guard let jarURL = serverJarURL else {
            throw ScrcpyError.serverJarMissing
        }
        log("JAR path: \(jarURL.path)", level: .ok)
        log("JAR exists on disk: \(FileManager.default.fileExists(atPath: jarURL.path))", level: .debug)

        // Step 3: Push JAR to device
        log("Step 3: Pushing server JAR to device…")
        let pushResult = await adb(serialArgs + [
            "push", jarURL.path, "/data/local/tmp/scrcpy-server.jar"
        ])
        log("push result: \(pushResult.trimmingCharacters(in: .whitespacesAndNewlines))",
            level: pushResult.lowercased().contains("error") || pushResult.lowercased().contains("failed") ? .error : .ok)
        if pushResult.lowercased().contains("error") || pushResult.lowercased().contains("adb: error") {
            throw ScrcpyError.pushFailed(pushResult)
        }

        // Step 4: Generate SCID and socket name
        scid = UInt32.random(in: 1...0x7FFFFFFF)
        let scidHex = String(format: "%08x", scid)
        let socketName = "scrcpy_\(scidHex)"
        log("Step 4: SCID=\(scid) socketName=\(socketName)", level: .debug)

        // Step 5: Clean up any stale tunnel
        log("Step 5: Removing stale reverse tunnel (if any)…")
        let removeResult = await adb(serialArgs + ["reverse", "--remove", "localabstract:\(socketName)"])
        log("reverse --remove: \(removeResult.trimmingCharacters(in: .whitespacesAndNewlines))", level: .debug)

        // Step 6: Start our TCP listener FIRST
        log("Step 6: Starting TCP listener on port \(listenPort)…")

        let (videoConn, controlConn): (NWConnection, NWConnection) = try await withThrowingTaskGroup(
            of: (NWConnection, NWConnection)?.self
        ) { group in

            group.addTask {
                try await self.listenForConnections(port: self.listenPort)
            }

            // Give the listener a moment to bind
            try await Task.sleep(for: .milliseconds(200))
            log("Listener ready. Setting up ADB reverse tunnel…")

            // Step 7: ADB reverse tunnel
            log("Step 7: adb reverse localabstract:\(socketName) tcp:\(self.listenPort)…")
            let reverseResult = await self.adb(serialArgs + [
                "reverse",
                "localabstract:\(socketName)",
                "tcp:\(self.listenPort)"
            ])
            let reverseClean = reverseResult.trimmingCharacters(in: .whitespacesAndNewlines)
            log("reverse result: '\(reverseClean)'",
                level: reverseClean.isEmpty || reverseClean.contains(socketName) ? .ok : .warn)

            if reverseClean.lowercased().contains("error") {
                throw ScrcpyError.reverseTunnelFailed(reverseResult)
            }

            // Step 8: Start scrcpy-server on device
            log("Step 8: Starting scrcpy-server 3.3.4 on device…")
            let serverArgs = serialArgs + [
                "shell",
                "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
                "app_process",
                "/",
                "com.genymobile.scrcpy.Server",
                "3.3.4",
                "scid=\(String(self.scid, radix: 16))",
                "log_level=info",
                "video_codec=h264",
                "audio=false",
                "control=true",
                "tunnel_forward=false",
                "max_size=0",
                "stay_awake=true",
                "power_on=false",
                "screen_off_timeout=0",
                "send_device_meta=true",
                "send_frame_meta=true",
                "send_dummy_byte=false",
                "send_codec_meta=true",
                "max_fps=90",
                "video_bit_rate=8000000",
            ]
            log("Server args: \(serverArgs.joined(separator: " "))", level: .debug)

            // Run adb shell in the background — it blocks until server exits
            Task {
                let shellResult = await self.adb(serverArgs)
                log("scrcpy-server exited: \(shellResult.trimmingCharacters(in: .whitespacesAndNewlines))",
                    level: .warn)
            }

            log("Step 8: Server started. Waiting for device to connect back…")
            return try await group.next()!!
        }

        log("Step 9: Got 2 connections from device ✓", level: .ok)

        // Step 9: Read handshake — 64-byte device name
        log("Step 9: Reading device name handshake (64 bytes)…")
        let nameData = try await videoConn.receiveExactly(64)
        let deviceName = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "Android Device"
        log("Device name: \(deviceName)", level: .ok)

        // Step 10: Read codec metadata
        log("Step 10: Reading codec metadata (12 bytes)…")
        let codecData = try await videoConn.receiveExactly(12)
        let codecID     = codecData.loadBigEndianUInt32(at: 0)
        let videoWidth  = Int(codecData.loadBigEndianUInt32(at: 4))
        let videoHeight = Int(codecData.loadBigEndianUInt32(at: 8))
        let codecStr    = String(bytes: [
            UInt8((codecID >> 24) & 0xFF), UInt8((codecID >> 16) & 0xFF),
            UInt8((codecID >>  8) & 0xFF), UInt8(codecID & 0xFF)
        ], encoding: .ascii) ?? "????"
        log("Codec: \(codecStr) | Resolution: \(videoWidth)×\(videoHeight)", level: .ok)

        guard codecID == 0x68323634 else {
            throw ScrcpyError.unsupportedCodec(codecID)
        }

        // Step 11: Hand off
        log("Step 11: Handing off to video stream and control socket…")
        await videoStream.start(connection: videoConn, width: videoWidth, height: videoHeight)
        await controlSocket.start(connection: controlConn, videoWidth: videoWidth, videoHeight: videoHeight)

        connectedDevice = deviceName
        connectedSerial = serial
        state = .connected
        log("──── Connected to \(deviceName) \(videoWidth)×\(videoHeight) ────", level: .ok)
    }

    // MARK: - TCP Listener

    private func listenForConnections(port: UInt16) async throws -> (NWConnection, NWConnection) {
        return try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(throwing: ScrcpyError.listenerFailed("Invalid port"))
                return
            }

            do {
                let listener = try NWListener(using: params, on: nwPort)
                self.tcpListener = listener

                final class ListenerState: @unchecked Sendable {
                    var connections: [NWConnection] = []
                    var resumed = false
                }
                let lstate = ListenerState()

                let netQueue = DispatchQueue(label: "scrcpy.listener", qos: .userInitiated)
                listener.newConnectionHandler = { conn in
                    let idx = lstate.connections.count
                    Task { @MainActor in log("TCP connection #\(idx + 1) accepted from \(conn.endpoint)", level: .ok) }
                    conn.start(queue: netQueue)
                    lstate.connections.append(conn)
                    if lstate.connections.count == 2 && !lstate.resumed {
                        lstate.resumed = true
                        continuation.resume(returning: (lstate.connections[0], lstate.connections[1]))
                        listener.cancel()
                    }
                }
                listener.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        Task { @MainActor in log("TCP listener ready on port \(port)", level: .ok) }
                    case .failed(let err):
                        Task { @MainActor in log("TCP listener failed: \(err)", level: .error) }
                        if !lstate.resumed {
                            lstate.resumed = true
                            continuation.resume(throwing: err)
                        }
                    default:
                        Task { @MainActor in log("TCP listener state: \(newState)", level: .debug) }
                    }
                }
                listener.start(queue: netQueue)
            } catch {
                log("Failed to create listener: \(error)", level: .error)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        log("Disconnecting…")
        connectTask?.cancel()
        connectTask = nil
        tcpListener?.cancel()
        tcpListener = nil
        await videoStream.stop()
        await controlSocket.stop()
        serverProcess?.terminate()
        serverProcess = nil
        state = .disconnected
        connectedDevice = nil
        connectedSerial = nil
        log("Disconnected.", level: .ok)
    }

    // MARK: - ADB helper

    @discardableResult
    func adb(_ args: [String]) async -> String {
        let path = adbPath
        return await withCheckedContinuation { continuation in
            // Run on a background thread so waitUntilExit() never blocks the main actor
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: out + err)
                } catch {
                    Task { @MainActor in log("adb exec error: \(error)", level: .error) }
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    private func extractSerial(from raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.contains("("), let start = raw.lastIndex(of: "("), let end = raw.lastIndex(of: ")") {
            return String(raw[raw.index(after: start)..<end])
        }
        return raw
    }
}

// MARK: - ScrcpyError

enum ScrcpyError: LocalizedError {
    case serverJarMissing
    case pushFailed(String)
    case reverseTunnelFailed(String)
    case listenerFailed(String)
    case handshakeFailed
    case unsupportedCodec(UInt32)

    var errorDescription: String? {
        switch self {
        case .serverJarMissing:
            return "scrcpy-server not found in app bundle."
        case .pushFailed(let msg):
            return "Failed to push server to device: \(msg)"
        case .reverseTunnelFailed(let msg):
            return "ADB reverse tunnel failed: \(msg)"
        case .listenerFailed(let msg):
            return "TCP listener error: \(msg)"
        case .handshakeFailed:
            return "Handshake with scrcpy-server failed."
        case .unsupportedCodec(let id):
            let b: [UInt8] = [(id>>24)&0xFF, (id>>16)&0xFF, (id>>8)&0xFF, id&0xFF].map { UInt8($0) }
            return "Unsupported codec: \(String(bytes: b, encoding: .ascii) ?? "????")"
        }
    }
}
