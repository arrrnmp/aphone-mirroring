// ConversationPanel.swift
// aPhone Mirroring
//
// Message thread view: scrollable bubble list with day dividers, contact header,
// and text-input bar. Also contains MessageBubble, DayDivider, groupedByDay(),
// messageDayLabel(), and the two DateFormatter file-scope constants they share.
//

import SwiftUI

// MARK: - Day grouping helpers

/// Groups an array of messages into (dayLabel, messages) sections.
func groupedByDay(_ messages: [BridgeMessage]) -> [(String, [BridgeMessage])] {
    var groups: [(String, [BridgeMessage])] = []
    var currentLabel: String?
    var currentGroup: [BridgeMessage] = []

    for msg in messages {
        let label = messageDayLabel(epochMillis: msg.timestamp)
        if label != currentLabel {
            if let current = currentLabel, !currentGroup.isEmpty {
                groups.append((current, currentGroup))
            }
            currentLabel = label
            currentGroup = [msg]
        } else {
            currentGroup.append(msg)
        }
    }
    if let current = currentLabel, !currentGroup.isEmpty {
        groups.append((current, currentGroup))
    }
    return groups
}

let _dayLabelWeekdayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
let _dayLabelDateFmt: DateFormatter    = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()

func messageDayLabel(epochMillis: Double) -> String {
    let date = Date(timeIntervalSince1970: epochMillis / 1000.0)
    let cal = Calendar.current
    if cal.isDateInToday(date)     { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
    return daysAgo < 7 ? _dayLabelWeekdayFmt.string(from: date) : _dayLabelDateFmt.string(from: date)
}

// MARK: - ConversationPanel

struct ConversationPanel: View {
    let thread: BridgeThread
    let messages: [BridgeMessage]
    let bridge: DataBridgeClient
    @State private var draftText = ""

    var body: some View {
        VStack(spacing: 0) {
            contactHeader

            Divider().opacity(0.1)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(groupedByDay(messages), id: \.0) { dayLabel, dayMessages in
                            DayDivider(label: dayLabel)
                            VStack(spacing: 6) {
                                ForEach(dayMessages) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.messageId)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) }
                    }
                }
            }

            Divider().opacity(0.1)

            messageInputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contactHeader: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color(hue: thread.hue, saturation: 0.6, brightness: 0.75))
                Text(thread.initials)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            Text(thread.contactName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    // Plain fill input bar — avoids glass-on-glass inside the panel
    private var messageInputBar: some View {
        HStack(spacing: 8) {
            TextField("Text Message", text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.08))
                )
            if !draftText.isEmpty {
                Button {
                    bridge.sendSMS(to: thread.contactPhone, body: draftText)
                    draftText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.smooth(duration: 0.2), value: draftText.isEmpty)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: BridgeMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 40) }
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .font(.system(size: 13))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(message.isFromMe ? Color.blue : Color.white.opacity(0.12))
                    )
                Text(message.timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if !message.isFromMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}

// MARK: - DayDivider

struct DayDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}
