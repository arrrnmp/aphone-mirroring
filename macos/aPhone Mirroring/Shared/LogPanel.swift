// LogPanel.swift
// aPhone Mirroring
//
// Debug log overlay sliding up from the bottom of PhonePanelView. Auto-scrolls to the latest
// entry only when the user is already at the bottom (tracked via onScrollGeometryChange).
// LogEntryRowView renders each entry with level-based color coding.
//

import SwiftUI

// MARK: - LogPanelView

struct LogPanelView: View {
    let appLog: AppLog
    let onClose: () -> Void

    @State private var isAtBottom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Debug Log", systemImage: "terminal.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Button("Clear") { appLog.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button { onClose() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.2)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appLog.entries) { entry in
                            LogEntryRowView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .frame(height: 220)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 20
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onChange(of: appLog.entries.count) { _, _ in
                    guard isAtBottom, let last = appLog.entries.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

// MARK: - LogEntryRowView

struct LogEntryRowView: View {
    let entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.6))
                .fixedSize()
            Text(entry.level.icon).font(.system(size: 10))
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
