//
//  DataBridgeModels.swift
//  aPhone Mirroring
//
//  Swift mirrors of the Android BridgeModels, used by DataBridgeClient and ContentView.
//

import Foundation
import AppKit

// MARK: - BridgeThread

struct BridgeThread: Identifiable, Codable, Equatable {
    let threadId: Int64
    let contactName: String
    let contactPhone: String
    let preview: String
    let timestamp: Double   // epoch millis from Android
    var unreadCount: Int

    var id: Int64 { threadId }

    var initials: String {
        let words = contactName.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var hue: Double {
        var hash = 5381
        for scalar in contactName.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Double(abs(hash) % 360) / 360.0
    }

    var timeLabel: String {
        BridgeRelativeDate.label(from: timestamp / 1000.0)
    }
}

// MARK: - BridgeMessage

struct BridgeMessage: Identifiable, Codable {
    let messageId: Int64
    let threadId: Int64
    let body: String
    let isFromMe: Bool
    let timestamp: Double   // epoch millis
    let isRead: Bool

    var id: Int64 { messageId }

    var timeLabel: String {
        let date = Date(timeIntervalSince1970: timestamp / 1000.0)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - BridgeCall

struct BridgeCall: Identifiable, Codable, Equatable {
    let callId: Int64
    let number: String
    let contactName: String?
    let callType: Int       // 1=incoming, 2=outgoing, 3=missed
    let duration: Int64     // seconds
    let timestamp: Double   // epoch millis

    var id: Int64 { callId }

    var displayName: String { contactName ?? number }

    var initials: String {
        let name = displayName
        if name == number || name == "Unknown" { return "?" }
        let words = name.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var hue: Double {
        let name = displayName
        var hash = 5381
        for scalar in name.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Double(abs(hash) % 360) / 360.0
    }

    var isMissed: Bool   { callType == 3 }
    var isOutgoing: Bool { callType == 2 }
    var isIncoming: Bool { callType == 1 }

    var durationLabel: String? {
        guard duration > 0 else { return nil }
        let min = duration / 60
        let sec = duration % 60
        return min > 0 ? "\(min)m \(sec)s" : "\(sec)s"
    }

    var timeLabel: String {
        BridgeRelativeDate.label(from: timestamp / 1000.0)
    }
}

// MARK: - BridgePhoto

struct BridgePhoto: Identifiable, Codable {
    let mediaId: Int64
    let filename: String
    let timestamp: Double   // epoch seconds (MediaStore DATE_ADDED)
    let filePath: String    // on-device absolute path for ADB pull

    var id: Int64 { mediaId }

    // Set after ADB pull completes; excluded from JSON encode/decode.
    var thumbnailImage: NSImage? = nil
    var localURL: URL? = nil

    enum CodingKeys: String, CodingKey {
        case mediaId, filename, timestamp, filePath
    }
}

// MARK: - BridgeContact

struct BridgeContact: Identifiable, Codable, Equatable {
    let contactId: Int64
    let displayName: String
    let phoneNumbers: [String]
    let emails: [String]
    let organization: String?
    let jobTitle: String?
    let notes: String?
    let birthday: String?
    let websites: [String]
    let addresses: [String]

    // Provide defaults for fields added after initial deployment
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contactId    = try c.decode(Int64.self,   forKey: .contactId)
        displayName  = try c.decode(String.self,  forKey: .displayName)
        phoneNumbers = try c.decode([String].self, forKey: .phoneNumbers)
        emails       = try c.decode([String].self, forKey: .emails)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        jobTitle     = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        notes        = try c.decodeIfPresent(String.self, forKey: .notes)
        birthday     = try c.decodeIfPresent(String.self, forKey: .birthday)
        websites     = (try? c.decode([String].self, forKey: .websites))  ?? []
        addresses    = (try? c.decode([String].self, forKey: .addresses)) ?? []
    }

    var id: Int64 { contactId }

    var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        guard !words.isEmpty else { return "?" }
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var hue: Double {
        var hash = 5381
        for scalar in displayName.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Double(abs(hash) % 360) / 360.0
    }
}

// MARK: - BridgeContactApp

struct BridgeContactAction: Codable {
    let dataId: Int64
    let mimeType: String
    let label: String
}

struct BridgeContactApp: Codable {
    let packageName: String
    let appName: String
    let icon: String?   // base64 PNG
    let actions: [BridgeContactAction]

    var iconImage: NSImage? {
        guard let b64 = icon, let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - BridgeCallState

struct BridgeCallState: Equatable {
    enum CallStateValue: String, Equatable { case ringing, active, idle }
    var state: CallStateValue
    var number: String
    var contactName: String?
}

// MARK: - BridgeRelativeDate

enum BridgeRelativeDate {
    static func label(from epochSeconds: Double) -> String {
        let date = Date(timeIntervalSince1970: epochSeconds)
        let interval = Date().timeIntervalSince(date)

        if interval < 60     { return "Just now" }
        if interval < 3600   { return "\(Int(interval / 60))m ago" }
        if interval < 86400  { return "\(Int(interval / 3600))h ago" }

        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "Yesterday" }

        if interval < 7 * 86400 {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE"
            return fmt.string(from: date)
        }

        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}
