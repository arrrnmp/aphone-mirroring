//
//  AppLog.swift
//  Scrcpy SwiftUI
//
//  Simple in-app logger. Call AppLog.shared.log(...) from anywhere.
//  Keeps the last 500 entries in memory; UI observes via @Published.
//

import Foundation
import Combine

enum LogLevel: String {
    case info  = "ℹ"
    case ok    = "✓"
    case warn  = "⚠"
    case error = "✗"
    case debug = "·"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String

    var formatted: String {
        let t = DateFormatter.logTime.string(from: date)
        return "\(t) \(level.rawValue) \(message)"
    }
}

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var entries: [LogEntry] = []

    private init() {}

    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        // Also print to Xcode console
        print("[\(level.rawValue)] \(message)")
    }

    func clear() { entries.removeAll() }
}

// Convenience free functions
func log(_ message: String, level: LogLevel = .info) {
    Task { @MainActor in AppLog.shared.log(message, level: level) }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
