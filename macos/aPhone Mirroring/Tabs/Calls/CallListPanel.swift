// CallListPanel.swift
// aPhone Mirroring
//
// Left panel of the Calls tab: search bar and scrollable CallRow list. CallRow shows avatar, name
// (red if missed), direction icon + duration, and timestamp. Selection highlighted with
// accentColor.opacity(0.15).
//

import SwiftUI

// MARK: - CallListPanel

struct CallListPanel: View {
    let calls: [BridgeCall]
    @Binding var selectedCall: BridgeCall?
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 8) {
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

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(calls) { call in
                        CallRow(
                            call: call,
                            isSelected: selectedCall?.id == call.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedCall = call }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

// MARK: - CallRow

struct CallRow: View {
    let call: BridgeCall
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hue: call.hue, saturation: 0.55, brightness: 0.70))
                    Text(call.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(call.displayName)
                        .font(.system(size: 13, weight: call.isMissed ? .semibold : .medium))
                        .foregroundStyle(call.isMissed ? .red : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: call.isOutgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(call.isMissed ? .red : call.isOutgoing ? Color.accentColor : .green)
                        if let dur = call.durationLabel {
                            Text(dur).font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Text("Missed").font(.system(size: 12)).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                }

                Spacer()

                Text(call.timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
