//
//  ScrcpyManager+Battery.swift
//  aPhone Mirroring
//
//  Battery polling and macOS menu bar status item.
//
//  Polling cadence: every 60 s (started on connect, stopped on disconnect).
//  Change guard: skips @Observable assignments when level and charging are unchanged,
//  preventing unnecessary UI refreshes and status bar rebuilds.
//

import AppKit

extension ScrcpyManager {

    // MARK: - Battery

    func startBatteryPolling() {
        batteryPollTask?.cancel()
        batteryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBattery()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopBatteryPolling() {
        batteryPollTask?.cancel()
        batteryPollTask = nil
    }

    func refreshBattery() async {
        guard let serial = connectedSerial else { return }
        let output = await adb(["-s", serial, "shell", "dumpsys", "battery"])
        guard let (level, charging) = parseBattery(output) else { return }
        guard batteryLevel != level || batteryCharging != charging else { return }
        batteryLevel = level
        batteryCharging = charging
        updateStatusBar(level: level, charging: charging)
        log("Battery: \(level)%\(charging ? " ⚡" : "")", level: .debug)
    }

    func parseBattery(_ output: String) -> (level: Int, charging: Bool)? {
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

    func setupStatusBar() {
        removeStatusBar()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "Android Device")
        button.image?.isTemplate = true
        button.toolTip = "Android battery"
    }

    func updateStatusBar(level: Int, charging: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = batteryLevelSymbol(level)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Battery \(level)%")
        button.image?.isTemplate = true
        button.title = " \(charging ? "⚡" : "")\(level)%"
        button.toolTip = "Android battery: \(level)%\(charging ? " (charging)" : "")"
    }

    func removeStatusBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func batteryLevelSymbol(_ level: Int) -> String {
        switch level {
        case 0..<13:  return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }
}
