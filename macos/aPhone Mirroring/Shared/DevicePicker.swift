// DevicePicker.swift
// aPhone Mirroring
//
// Device selection UI shown on the disconnected state card when ADB devices are available.
// DevicePickerView lists DeviceRowViews (model name + serial) with a Refresh button. Tapping a
// row calls onConnect(deviceSerial:).
//

import SwiftUI
import AppKit

// MARK: - DevicePickerView

struct DevicePickerView: View {
    let devices: [String]
    let onConnect: (String) -> Void
    let onRefresh: () -> Void
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { idx, dev in
                        DeviceRowView(device: dev) { onConnect(dev) }
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .glassEffectID("dev-\(idx)", in: ns)
                    }
                }
            }
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - DeviceRowView

struct DeviceRowView: View {
    let device: String
    let action: () -> Void

    private var displayName: String {
        if let p = device.firstIndex(of: "(") {
            return String(device[device.startIndex..<p]).trimmingCharacters(in: .whitespaces)
        }
        return device
    }
    private var serial: String? {
        guard let o = device.firstIndex(of: "("),
              let c = device.firstIndex(of: ")") else { return nil }
        let s = String(device[device.index(after: o)..<c])
        return s.count > 12 ? String(s.prefix(10)) + "…" : s
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "smartphone")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if let s = serial {
                        Text(s)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
