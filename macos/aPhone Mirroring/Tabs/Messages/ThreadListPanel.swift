// ThreadListPanel.swift
// aPhone Mirroring
//
// Left panel of the Messages tab: search bar, compose button, scrollable thread list. ThreadRow
// shows avatar, name (bold if unread), preview, timestamp, and unread badge. Selection highlighted
// with accentColor.opacity(0.15).
//

import SwiftUI
import AppKit

// MARK: - ThreadListPanel

struct ThreadListPanel: View {
    let threads: [BridgeThread]
    @Binding var selectedThread: BridgeThread?
    @Binding var searchText: String
    let onCompose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Search bar + compose button row
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Message")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(threads) { thread in
                        ThreadRow(
                            thread: thread,
                            isSelected: selectedThread?.id == thread.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedThread = thread }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

// MARK: - ThreadRow

struct ThreadRow: View {
    let thread: BridgeThread
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hue: thread.hue, saturation: 0.6, brightness: 0.75))
                    Text(thread.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.contactName)
                            .font(.system(size: 13, weight: thread.unreadCount > 0 ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(thread.timeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(thread.preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if thread.unreadCount > 0 {
                            ZStack {
                                Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                                Text("\(thread.unreadCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}
