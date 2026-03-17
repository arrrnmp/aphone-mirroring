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
    @Published var batteryLevel: Int? = nil
    @Published var batteryCharging: Bool = false

    // Serial of the currently connected device, used for disconnect detection
    private var connectedSerial: String? = nil

    private var batteryPollTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?

    let videoStream   = ScrcpyVideoStream()
    let audioStream   = ScrcpyAudioStream()
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
    private var serverTask: Task<Void, Never>?   // untracked adb shell that runs the server
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

        // Step 4b: Detect display refresh rate to pass as max_fps
        log("Step 4b: Detecting display refresh rate…")
        let maxFps = await detectRefreshRate(serialArgs: serialArgs)

        // Step 5: Clean up any stale tunnel
        log("Step 5: Removing stale reverse tunnel (if any)…")
        let removeResult = await adb(serialArgs + ["reverse", "--remove", "localabstract:\(socketName)"])
        log("reverse --remove: \(removeResult.trimmingCharacters(in: .whitespacesAndNewlines))", level: .debug)

        // Step 6: Start our TCP listener FIRST
        log("Step 6: Starting TCP listener on port \(listenPort)…")

        let conns: [NWConnection] = try await withThrowingTaskGroup(
            of: [NWConnection]?.self
        ) { group in

            group.addTask {
                // video + audio + control = 3 connections
                try await self.listenForConnections(port: self.listenPort, count: 3)
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
                "audio=true",
                "audio_codec=raw",
                "control=true",
                "tunnel_forward=false",
                "max_size=0",
                "stay_awake=false",
                "power_on=false",
                "screen_off_timeout=0",
                "send_device_meta=true",
                "send_frame_meta=true",
                "send_dummy_byte=false",
                "send_codec_meta=true",
                "max_fps=\(maxFps)",
                "video_bit_rate=8000000",
                "clipboard_autosync=true",
            ]
            log("Server args: \(serverArgs.joined(separator: " "))", level: .debug)

            // Run adb shell in the background — it blocks until server exits.
            // Stored so disconnect() can cancel it, which terminates the process.
            self.serverTask = Task {
                let shellResult = await self.adb(serverArgs)
                log("scrcpy-server exited: \(shellResult.trimmingCharacters(in: .whitespacesAndNewlines))",
                    level: .warn)
            }

            log("Step 8: Server started. Waiting for device to connect back…")
            return try await group.next()!!
        }

        log("Step 9: Got 3 connections from device ✓", level: .ok)

        let videoConn   = conns[0]
        let audioConn   = conns[1]
        let controlConn = conns[2]

        // Step 9: Read handshake — 64-byte device name (video connection only)
        log("Step 9: Reading device name handshake (64 bytes)…")
        let nameData = try await videoConn.receiveExactly(64)
        let deviceName = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "Android Device"
        log("Device name: \(deviceName)", level: .ok)

        // Step 10: Read video codec metadata
        log("Step 10: Reading video codec metadata (12 bytes)…")
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

        // Step 11: Hand off — audio stream reads its own 12-byte metadata internally
        log("Step 11: Handing off to video / audio / control…")
        await videoStream.start(connection: videoConn, width: videoWidth, height: videoHeight)
        await audioStream.start(connection: audioConn)
        await controlSocket.start(connection: controlConn, videoWidth: videoWidth, videoHeight: videoHeight)
        // Wire up disconnect detection: if any connection drops unexpectedly,
        // transition to the error state so the user sees the error screen.
        videoStream.onDisconnect   = { [weak self] in self?.handleUnexpectedDisconnect() }
        audioStream.onDisconnect   = { [weak self] in self?.handleUnexpectedDisconnect() }
        controlSocket.onDisconnect = { [weak self] in self?.handleUnexpectedDisconnect() }

        connectedDevice = deviceName
        connectedSerial = serial
        state = .connected
        log("──── Connected to \(deviceName) \(videoWidth)×\(videoHeight) ────", level: .ok)
        setupStatusBar()
        startBatteryPolling()
    }

    // MARK: - TCP Listener

    private func listenForConnections(port: UInt16, count: Int) async throws -> [NWConnection] {
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
                    if lstate.connections.count == count && !lstate.resumed {
                        lstate.resumed = true
                        continuation.resume(returning: lstate.connections)
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

    // MARK: - Unexpected disconnect

    private func handleUnexpectedDisconnect() {
        guard state == .connected else { return }
        log("Remote host closed the connection — disconnecting", level: .error)
        Task { @MainActor [weak self] in
            guard let self, self.state == .connected else { return }
            await self.disconnect()
            self.state = .error("Device closed the connection unexpectedly.")
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        log("Disconnecting…")
        videoStream.onDisconnect   = nil
        audioStream.onDisconnect   = nil
        controlSocket.onDisconnect = nil
        batteryPollTask?.cancel()
        batteryPollTask = nil
        removeStatusBar()
        connectTask?.cancel()
        connectTask = nil
        serverTask?.cancel()   // cancellation triggers process.terminate() via withTaskCancellationHandler
        serverTask = nil
        tcpListener?.cancel()
        tcpListener = nil
        await videoStream.stop()
        await audioStream.stop()
        await controlSocket.stop()
        serverProcess?.terminate()
        serverProcess = nil
        state = .disconnected
        connectedDevice = nil
        connectedSerial = nil
        batteryLevel = nil
        batteryCharging = false
        log("Disconnected.", level: .ok)
    }

    // MARK: - File push (drag & drop)

    func pushFiles(_ urls: [URL]) async {
        guard let serial = connectedSerial else { return }
        let serialArgs = ["-s", serial]

        let apkURLs  = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "apk" }
        let fileURLs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "apk" }

        // ── APK installation ──────────────────────────────────────────────────
        for url in apkURLs {
            let filename = url.lastPathComponent
            log("Installing \(filename)…")
            // Copy to a temp path so iCloud/alias placeholders are resolved
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch {
                log("Could not read \(filename): \(error.localizedDescription)", level: .error)
                if accessed { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
            let result = await adb(serialArgs + ["install", "-r", tmp.path])
            try? FileManager.default.removeItem(at: tmp)
            if result.lowercased().contains("success") {
                log("Installed \(filename) ✓", level: .ok)
            } else {
                log("Install failed for \(filename): \(result.trimmingCharacters(in: .whitespacesAndNewlines))", level: .error)
            }
        }

        guard !fileURLs.isEmpty else { return }

        // ── Regular file push ─────────────────────────────────────────────────
        log("Pushing \(fileURLs.count) file(s) to /sdcard/Download/")

        // Copy each file to a temp dir so that:
        //   • Cloud/iCloud placeholders are fully materialised before adb reads them
        //   • Lazy-loaded drag assets (Photos.app, etc.) are resolved to real data
        //   • adb subprocess gets a simple, stable path without any alias indirection
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrcpy-push-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        struct PushItem { let src: URL; let filename: String }
        var items: [PushItem] = []

        for url in fileURLs {
            let filename = url.lastPathComponent
            let dst = tmp.appendingPathComponent(filename)
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                items.append(PushItem(src: dst, filename: filename))
            } catch {
                log("Could not read \(filename): \(error.localizedDescription)", level: .error)
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        var pushedFilenames: [String] = []
        for item in items {
            log("Pushing \(item.filename)…")
            let result = await adb(serialArgs + ["push", item.src.path, "/sdcard/Download/\(item.filename)"])
            try? FileManager.default.removeItem(at: item.src)
            if result.lowercased().contains("error") || result.lowercased().contains("failed") {
                log("Push failed for \(item.filename): \(result.trimmingCharacters(in: .whitespacesAndNewlines))", level: .error)
            } else {
                log("Pushed \(item.filename) ✓", level: .ok)
                pushedFilenames.append(item.filename)
            }
        }
        try? FileManager.default.removeItem(at: tmp)

        // Notify media scanner for each pushed file
        for filename in pushedFilenames {
            await adb(serialArgs + [
                "shell", "am", "broadcast",
                "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                "-d", "file:///sdcard/Download/\(filename)"
            ])
        }

        // Open Downloads folder on device
        if !pushedFilenames.isEmpty {
            await adb(serialArgs + [
                "shell", "am", "start",
                "-a", "android.intent.action.VIEW",
                "-d", "content://com.android.externalstorage.documents/document/primary%3ADownload",
                "-t", "vnd.android.document/directory"
            ])
            log("Opened Downloads folder on device", level: .debug)
        }
    }

    // MARK: - Battery

    private func startBatteryPolling() {
        batteryPollTask?.cancel()
        batteryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBattery()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func refreshBattery() async {
        guard let serial = connectedSerial else { return }
        let output = await adb(["-s", serial, "shell", "dumpsys", "battery"])
        guard let (level, charging) = parseBattery(output) else { return }
        batteryLevel = level
        batteryCharging = charging
        updateStatusBar(level: level, charging: charging)
        log("Battery: \(level)%\(charging ? " ⚡" : "")", level: .debug)
    }

    private func parseBattery(_ output: String) -> (level: Int, charging: Bool)? {
        var level: Int? = nil
        var status = 0
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("level:"), let v = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                level = v
            } else if t.hasPrefix("status:"), let v = Int(t.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                status = v
            }
        }
        guard let level else { return nil }
        // status 2 = CHARGING, 5 = FULL (on charger)
        return (level, status == 2 || status == 5)
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        removeStatusBar()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "Android Device")
        button.image?.isTemplate = true
        button.toolTip = "Android battery"
    }

    private func updateStatusBar(level: Int, charging: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = batteryLevelSymbol(level)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Battery \(level)%")
        button.image?.isTemplate = true
        button.title = " \(charging ? "⚡" : "")\(level)%"
        button.toolTip = "Android battery: \(level)%\(charging ? " (charging)" : "")"
    }

    private func removeStatusBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func batteryLevelSymbol(_ level: Int) -> String {
        switch level {
        case 0..<13:  return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    // MARK: - Refresh rate detection

    /// Queries the device's display refresh rate via `dumpsys display`.
    /// Falls back to 60 if it can't be determined.
    private func detectRefreshRate(serialArgs: [String]) async -> Int {
        // Run grep on the device side so we receive only one line instead of the full
        // dumpsys display output (hundreds of KB). Reading the full output causes a
        // pipe-buffer deadlock: the device blocks writing while we wait for exit.

        // Prefer mSupportedRefreshRates=[90.0, …] — first value is the device's peak rate.
        let supported = await adb(serialArgs + ["shell",
            "dumpsys display | grep -m1 mSupportedRefreshRates"])
        if let bracketRange = supported.range(of: "mSupportedRefreshRates=[") {
            let tail = supported[bracketRange.upperBound...]
            let firstNum = tail.prefix(while: { $0.isNumber || $0 == "." })
            if let fps = Double(firstNum), fps > 0, fps <= 360 {
                let rate = Int(fps.rounded())
                log("Display peak refresh rate: \(rate) Hz", level: .ok)
                return rate
            }
        }

        // Fallback: current active refresh rate.
        let active = await adb(serialArgs + ["shell",
            "dumpsys display | grep -m1 mRefreshRate"])
        if let range = active.range(of: "mRefreshRate=") {
            let tail = active[range.upperBound...]
            let numStr = tail.prefix(while: { $0.isNumber || $0 == "." })
            if let fps = Double(numStr), fps > 0, fps <= 360 {
                let rate = Int(fps.rounded())
                log("Display refresh rate (active): \(rate) Hz", level: .ok)
                return rate
            }
        }

        log("Could not detect refresh rate — defaulting to 60 Hz", level: .warn)
        return 60
    }

    // MARK: - ADB helper

    @discardableResult
    func adb(_ args: [String]) async -> String {
        let path = adbPath
        // Create Process here so the cancellation handler can reach it
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        // withTaskCancellationHandler ensures that if the Swift Task is cancelled
        // (e.g. on disconnect or app quit), process.terminate() is called immediately,
        // unblocking waitUntilExit() on the background thread and avoiding EXC_BAD_ACCESS.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
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
        } onCancel: {
            // Called on an arbitrary thread when the task is cancelled;
            // terminate() is thread-safe on Process.
            process.terminate()
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
