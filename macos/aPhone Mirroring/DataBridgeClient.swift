//
//  DataBridgeClient.swift
//  aPhone Mirroring
//
//  Connects to the Android DataBridgeService over a local TCP port forwarded via ADB.
//  Fetches real SMS threads, messages, call log, and photos.
//  Delivers Android notifications to macOS Notification Center.
//

import Foundation
import Combine
import Network
import AppKit
import UserNotifications

// MARK: - DataBridgeClient

@MainActor
final class DataBridgeClient: ObservableObject {

    @Published var threads:     [BridgeThread]           = []
    @Published var messages:    [Int64: [BridgeMessage]] = [:]
    @Published var calls:       [BridgeCall]             = []
    @Published var photos:      [BridgePhoto]            = []
    @Published var contacts:    [BridgeContact]          = []
    @Published var activeCall:      BridgeCallState?      = nil
    @Published var callAudioError:  String?               = nil  // "hfp_unavailable" etc.
    /// Keyed by phone number string; nil means not yet loaded for that number.
    @Published var contactApps: [String: [BridgeContactApp]] = [:]
    @Published var isConnected  = false
    @Published var isLoading    = false
    @Published var photosHasMore = true   // false once Android returns a partial page

    private var connection:       NWConnection?
    private var readTask:         Task<Void, Never>?
    private var retryTask:        Task<Void, Never>?
    private var lineBuffer        = Data()
    private var retryDelay:       TimeInterval = 2
    private var isBootstrapped    = false
    private var photosOffset:     Int = 0
    private var isLoadingPhotos:  Bool = false
    private let photosPageSize    = 50

    /// AppDelegate uses this to send notification action responses back through the bridge.
    nonisolated(unsafe) static var shared: DataBridgeClient?

    private var notifCategories: Set<String> = []   // category IDs already registered

    private var currentSerial: String?
    private weak var manager: ScrcpyManager?

    // MARK: - Lifecycle

    func start(serial: String?, manager: ScrcpyManager) async {
        DataBridgeClient.shared = self
        self.currentSerial = serial
        self.manager = manager
        retryDelay = 2
        await setupForward()
        await connect()
    }

    // Runs once at startup (and on each retry after a disconnect).
    // Separated from connect() so retries don't re-run adb setup.
    private func setupForward() async {
        guard let manager else { return }
        let serial = currentSerial
        let serialArgs: [String] = serial.map { ["-s", $0] } ?? []
        _ = await manager.adb(serialArgs + ["shell", "am", "start-foreground-service",
                                             "-n", "com.aaronmompie.phoneconnect/.DataBridgeService"])
        _ = await manager.adb(serialArgs + ["forward", "--remove", "tcp:27184"])
        _ = await manager.adb(serialArgs + ["forward", "tcp:27184", "tcp:27184"])
        // Give the service time to bind to port 27184
        try? await Task.sleep(for: .milliseconds(800))
    }

    func stop() async {
        if DataBridgeClient.shared === self { DataBridgeClient.shared = nil }
        retryTask?.cancel(); retryTask = nil
        readTask?.cancel();  readTask  = nil
        connection?.cancel(); connection = nil
        lineBuffer.removeAll()
        isConnected = false
        isLoading   = false
        threads = []; messages = [:]; calls = []; photos = []; contacts = []
        activeCall = nil; contactApps = [:]
        photosOffset = 0; photosHasMore = true; isLoadingPhotos = false
    }

    // MARK: - Connection

    private func connect() async {
        guard !Task.isCancelled else { return }

        // Cancel any existing connection before starting a new one
        connection?.cancel()
        connection = nil

        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 27184)!,
            using: NWParameters.tcp
        )
        connection = conn

        readTask = Task.detached { [weak self] in
            await self?.readLoop(conn: conn)
        }
    }

    private func readLoop(conn: NWConnection) async {
        do {
            try await waitForReady(conn: conn)
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.isConnected = false
                self?.scheduleRetry()
            }
            return
        }

        guard !Task.isCancelled else { conn.cancel(); return }

        await MainActor.run { [weak self] in
            self?.isConnected = true
            self?.isLoading   = true
            self?.isBootstrapped = false
            log("DataBridge: connected to Android data service", level: .ok)
        }

        // Bootstrap: ping first, then fetch all data on pong
        sendRaw(conn: conn, json: #"{"type":"ping"}"#)

        // Heartbeat: ping every 20s so the Android service knows the Mac is still there
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                self?.sendRaw(conn: conn, json: #"{"type":"ping"}"#)
            }
        }
        defer { heartbeat.cancel() }

        var buffer = Data()
        do {
            while !Task.isCancelled {
                let chunk = try await conn.receiveAvailable(maxLength: 8192)
                guard !chunk.isEmpty else { continue }
                buffer.append(chunk)

                // Process all complete newline-delimited JSON lines
                while let idx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer.removeSubrange(buffer.startIndex...idx)
                    guard let line = String(data: lineData, encoding: .utf8),
                          !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    await MainActor.run { [weak self] in self?.handleResponse(line) }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                log("DataBridge: disconnected — \(error.localizedDescription)", level: .warn)
                self?.isConnected = false
                self?.scheduleRetry()
            }
        }
    }

    // MARK: - Wait for Connection

    private func waitForReady(conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ResumeOnce(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:     box.resume()
                case .failed(let e): box.resume(throwing: e)
                case .cancelled: box.resume(throwing: NWError.posix(.ECANCELED))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - Response Handling

    private func handleResponse(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {

        case "pong":
            guard !isBootstrapped else { break }
            isBootstrapped = true
            photosOffset = 0; photosHasMore = true
            sendRequest(["type": "get_threads"])
            sendRequest(["type": "get_calls"])
            sendRequest(["type": "get_photos", "offset": 0, "limit": photosPageSize])
            sendRequest(["type": "get_contacts"])

        case "threads_response":
            if let arr = obj["threads"],
               let d = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([BridgeThread].self, from: d) {
                threads = decoded
                isLoading = false
            }

        case "messages_response":
            guard let threadId = jsonInt64(obj, "threadId"),
                  let arr = obj["messages"],
                  let d = try? JSONSerialization.data(withJSONObject: arr),
                  let decoded = try? JSONDecoder().decode([BridgeMessage].self, from: d) else { return }
            messages[threadId] = decoded

        case "calls_response":
            if let arr = obj["calls"],
               let d = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([BridgeCall].self, from: d) {
                calls = decoded
            }

        case "photos_response":
            isLoadingPhotos = false
            let offset = Int(jsonInt64(obj, "offset") ?? 0)
            if let arr = obj["photos"],
               let d = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([BridgePhoto].self, from: d) {
                if offset == 0 { photos = decoded } else { photos.append(contentsOf: decoded) }
                photosOffset = offset + decoded.count
                photosHasMore = decoded.count >= photosPageSize
                if offset == 0 { isLoading = false }
            }

        case "thumbnail_response":
            guard let mediaId = jsonInt64(obj, "mediaId"),
                  let b64 = obj["jpeg"] as? String,
                  let imageData = Data(base64Encoded: b64),
                  let image = NSImage(data: imageData) else { return }
            if let idx = photos.firstIndex(where: { $0.mediaId == mediaId }) {
                photos[idx].thumbnailImage = image
            }

        case "contacts_response":
            if let arr = obj["contacts"],
               let d = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([BridgeContact].self, from: d) {
                contacts = decoded
            }

        case "call_state":
            let stateStr = obj["state"] as? String ?? ""
            let number   = obj["number"] as? String ?? ""
            let name     = obj["contactName"] as? String
            switch stateStr {
            case "ringing":
                activeCall = BridgeCallState(state: .ringing, number: number, contactName: name)
            case "active":
                let prev = activeCall
                activeCall = BridgeCallState(
                    state: .active,
                    number: number.isEmpty ? (prev?.number ?? "") : number,
                    contactName: name ?? prev?.contactName
                )
            case "idle":
                activeCall = nil
            default: break
            }

        case "contact_apps_response":
            guard let phone = obj["phone"] as? String,
                  let arr = obj["apps"],
                  let d = try? JSONSerialization.data(withJSONObject: arr),
                  let decoded = try? JSONDecoder().decode([BridgeContactApp].self, from: d) else { return }
            contactApps[phone] = decoded

        case "new_sms":
            // Refresh thread list and affected conversation
            sendRequest(["type": "get_threads"])
            if let threadId = jsonInt64(obj, "threadId") {
                sendRequest(["type": "get_messages", "threadId": threadId])
            }

        case "call_audio_error":
            callAudioError = obj["error"] as? String ?? "unknown"

        case "new_call":
            sendRequest(["type": "get_calls"])

        case "push_notification":
            log("Notification received: \(obj["title"] as? String ?? "(no title)") from \(obj["pkg"] as? String ?? "?")", level: .info)
            deliverMacNotification(obj)

        default:
            break
        }
    }

    // MARK: - macOS Notification Center

    private func deliverMacNotification(_ obj: [String: Any]) {
        guard let title = obj["title"] as? String,
              let text  = obj["text"]  as? String else { return }

        let pkg        = obj["pkg"]       as? String ?? ""
        let notifKey   = obj["notifKey"]  as? String ?? ""
        let actionsArr = obj["actions"]   as? [[String: Any]] ?? []

        // Build notification category from the action list
        let center = UNUserNotificationCenter.current()
        let categoryId: String
        let isNewCategory: Bool

        if actionsArr.isEmpty {
            categoryId = "android_info"
            isNewCategory = false
        } else {
            // Stable ID from action titles so identical action sets share a category
            let key = actionsArr.compactMap { $0["title"] as? String }.joined(separator: "|")
            categoryId = "android_\(abs(key.hashValue))"
            isNewCategory = !notifCategories.contains(categoryId)
            if isNewCategory {
                notifCategories.insert(categoryId)
                let unActions: [UNNotificationAction] = actionsArr.compactMap { a in
                    guard let id   = a["id"]    as? Int,
                          let t    = a["title"] as? String else { return nil }
                    let hasReply = a["hasReply"] as? Bool ?? false
                    if hasReply {
                        return UNTextInputNotificationAction(
                            identifier: "ACTION_\(id)", title: t, options: [],
                            textInputButtonTitle: "Send", textInputPlaceholder: "Reply…"
                        )
                    }
                    return UNNotificationAction(identifier: "ACTION_\(id)", title: t, options: [])
                }
                let category = UNNotificationCategory(
                    identifier: categoryId, actions: unActions,
                    intentIdentifiers: [], options: []
                )
                center.getNotificationCategories { existing in
                    center.setNotificationCategories(existing.union([category]))
                }
            }
        }

        let content = UNMutableNotificationContent()
        content.title              = title
        content.body               = text
        content.sound              = .default
        content.categoryIdentifier = categoryId
        content.userInfo           = ["notifKey": notifKey]

        let requestId = "android-\(Int(Date().timeIntervalSince1970 * 1000))"
        let req = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)

        // If we just registered a new category, give the system a tick to process it
        let delay: TimeInterval = isNewCategory ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            center.add(req) { error in
                DispatchQueue.main.async {
                    if let error {
                        log("Notification delivery failed: \(error.localizedDescription)", level: .warn)
                    }
                }
            }
        }
    }

    // MARK: - Public Fetch Methods

    func fetchMessages(threadId: Int64) {
        sendRequest(["type": "get_messages", "threadId": threadId])
    }

    /// Requests a 200×200 JPEG thumbnail from Android over TCP (fast).
    func fetchThumbnail(mediaId: Int64) {
        guard let idx = photos.firstIndex(where: { $0.mediaId == mediaId }),
              photos[idx].thumbnailImage == nil else { return }
        sendRequest(["type": "get_thumbnail", "mediaId": mediaId])
    }

    /// Loads the next page of photos from Android.
    func loadMorePhotos() {
        guard photosHasMore, isConnected, !isLoadingPhotos else { return }
        isLoadingPhotos = true
        sendRequest(["type": "get_photos", "offset": photosOffset, "limit": photosPageSize])
    }

    /// Sends a notification action response back to Android (reply text, button tap, etc.).
    func sendNotificationAction(notifKey: String, actionIndex: Int, replyText: String?) {
        var dict: [String: Any] = ["type": "notification_action", "notifKey": notifKey, "actionIndex": actionIndex]
        if let text = replyText { dict["replyText"] = text }
        sendRequest(dict)
    }

    /// Opens a URL on the Android device (launches WhatsApp, Telegram, Signal, etc.).
    func openUrl(_ url: String) {
        sendRequest(["type": "open_url", "url": url])
    }

    /// Sends a call control action to Android (hangup, mute, unmute, use_mac_audio, use_phone_audio).
    func sendCallAction(_ action: String) {
        sendRequest(["type": "call_action", "action": action])
    }

    /// Opens Bluetooth settings on the Android device (so user can enable Call Audio for the Mac).
    func openBluetoothSettingsOnPhone() {
        callAudioError = nil
        sendRequest(["type": "open_bluetooth_settings"])
    }

    /// Directly initiates a phone call on the Android device (ACTION_CALL).
    func placeCall(_ phone: String) {
        sendRequest(["type": "place_call", "phone": phone])
    }

    /// Sends an SMS to the given phone number from the Android device.
    func sendSMS(to phone: String, body: String) {
        sendRequest(["type": "send_sms", "to": phone, "body": body])
    }

    /// Requests the list of connected third-party apps for a contact phone number.
    func fetchContactApps(phone: String, name: String? = nil) {
        var req: [String: Any] = ["type": "get_contact_apps", "phone": phone]
        if let name { req["name"] = name }
        sendRequest(req)
    }

    /// Fires the intent for a specific contact data row (e.g. open Signal chat).
    func executeContactAction(dataId: Int64, mimeType: String) {
        sendRequest(["type": "execute_contact_action", "dataId": dataId, "mimeType": mimeType])
    }

    /// Zeros the unread badge locally and asks Android to mark the thread as read in the SMS DB.
    func markRead(threadId: Int64) {
        if let idx = threads.firstIndex(where: { $0.threadId == threadId }),
           threads[idx].unreadCount > 0 {
            threads[idx].unreadCount = 0
        }
        sendRequest(["type": "mark_read", "threadId": threadId])
    }

    /// ADB-pulls the full-resolution photo, updates the cell thumbnail with the best quality
    /// possible (preserving aspect ratio, max 800px), then opens it in the default viewer.
    func openFullPhoto(mediaId: Int64) {
        guard let manager else { return }
        let serial = currentSerial
        let serialArgs: [String] = serial.map { ["-s", $0] } ?? []

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let photo = photos.first(where: { $0.mediaId == mediaId }),
                  !photo.filePath.isEmpty else { return }
            let tmpURL = Self.tmpURL(for: photo)
            if !FileManager.default.fileExists(atPath: tmpURL.path) {
                _ = await manager.adb(serialArgs + ["pull", photo.filePath, tmpURL.path])
            }
            if let raw = NSImage(contentsOf: tmpURL),
               let i = photos.firstIndex(where: { $0.mediaId == mediaId }) {
                // Replace TCP low-res thumb with best-quality version preserving aspect ratio
                photos[i].thumbnailImage = Self.aspectFitDownsample(raw, maxSide: 800)
                photos[i].localURL = tmpURL
            }
            NSWorkspace.shared.open(tmpURL)
        }
    }

    private static func tmpURL(for photo: BridgePhoto) -> URL {
        let ext = (photo.filePath as NSString).pathExtension.lowercased()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("aphone-photo-\(photo.mediaId).\(ext.isEmpty ? "jpg" : ext)")
    }

    private static func aspectFitDownsample(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return image }
        let scale = min(maxSide / w, maxSide / h, 1.0)  // never upscale
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }

    // MARK: - Send

    private func sendRequest(_ dict: [String: Any]) {
        guard let conn = connection, isConnected else { return }
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: d, encoding: .utf8) else { return }
        sendRaw(conn: conn, json: json)
    }

    private func sendRaw(conn: NWConnection, json: String) {
        let data = Data((json + "\n").utf8)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Retry

    private func scheduleRetry() {
        guard currentSerial != nil || manager != nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Re-run ADB setup on every retry so the forward is always fresh
            await self?.setupForward()
            await self?.connect()
        }
    }

    // MARK: - Helpers

    private func jsonInt64(_ obj: [String: Any], _ key: String) -> Int64? {
        if let v = obj[key] as? Int64  { return v }
        if let v = obj[key] as? Int    { return Int64(v) }
        if let v = obj[key] as? NSNumber { return v.int64Value }
        return nil
    }
}

// MARK: - ResumeOnce (thread-safe one-shot continuation wrapper)

private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(); cont = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        cont?.resume(throwing: error); cont = nil
    }
}
