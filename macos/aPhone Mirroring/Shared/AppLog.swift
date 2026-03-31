//
//  AppLog.swift
//  aPhone Mirroring
//
//  Simple in-app logger. Call the free `log()` function from anywhere.
//  Keeps the last 500 entries in memory; SwiftUI views observe via @Observable.
//

import Foundation
import SwiftUI

enum LogLevel: String {
    case info  = "ℹ"
    case ok    = "✓"
    case warn  = "⚠"
    case error = "✗"
    case debug = "·"

    var icon: String { rawValue }

    var color: Color {
        switch self {
        case .info:  return .white.opacity(0.75)
        case .ok:    return .green
        case .warn:  return .yellow
        case .error: return .red
        case .debug: return .white.opacity(0.45)
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String

    var timestamp: String { DateFormatter.logTime.string(from: date) }

    var formatted: String { "\(timestamp) \(level.rawValue) \(message)" }
}

@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()

    private(set) var entries: [LogEntry] = []

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

// Convenience free function — safe to call from any isolation context.
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
