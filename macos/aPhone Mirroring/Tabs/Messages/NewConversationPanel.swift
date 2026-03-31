// NewConversationPanel.swift
// aPhone Mirroring
//
// Compose panel for new SMS threads (no existing BridgeThread). Shows a To: field, empty-state
// message area, and text input bar. Displayed when the user taps the compose button; dismissed on
// send or cancel.
//

import SwiftUI

// MARK: - NewConversationPanel

struct NewConversationPanel: View {
    let initialPhone: String
    let bridge: DataBridgeClient
    let onSent: () -> Void
    let onCancel: () -> Void

    @State private var recipientPhone: String
    @State private var draftText = ""

    init(initialPhone: String, bridge: DataBridgeClient,
         onSent: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initialPhone = initialPhone
        self.bridge = bridge
        self.onSent = onSent
        self.onCancel = onCancel
        self._recipientPhone = State(initialValue: initialPhone)
    }

    var body: some View {
        VStack(spacing: 0) {
            // To: field + cancel button
            HStack(spacing: 8) {
                Text("To:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Phone number", text: $recipientPhone)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.1)

            Spacer()

            Text("No messages yet")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Spacer()

            Divider().opacity(0.1)

            // Input bar
            HStack(spacing: 8) {
                TextField("Text Message", text: $draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.08)))
                if !draftText.isEmpty {
                    Button {
                        let phone = recipientPhone.trimmingCharacters(in: .whitespaces)
                        guard !phone.isEmpty else { return }
                        bridge.sendSMS(to: phone, body: draftText)
                        draftText = ""
                        onSent()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
