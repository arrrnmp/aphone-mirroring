// MessagesTabView.swift
// aPhone Mirroring
//
// Top-level Messages tab layout: two-panel split (ThreadListPanel left,
// ConversationPanel/NewConversationPanel right). Handles SMS navigation from other tabs
// (navigateSMSPhone binding), auto-selects first thread on load, and fetches + marks-read on
// thread selection.
//

import SwiftUI

// MARK: - MessagesTabView

struct MessagesTabView: View {
    @Binding var listWidth: CGFloat
    let bridge: DataBridgeClient
    @Binding var navigateSMSPhone: String?
    @State private var selectedThread: BridgeThread? = nil
    @State private var pendingPhone: String? = nil   // non-nil → show NewConversationPanel
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredThreads: [BridgeThread] {
        guard !searchText.isEmpty else { return bridge.threads }
        return bridge.threads.filter {
            $0.contactName.localizedCaseInsensitiveContains(searchText) ||
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — thread list
            ThreadListPanel(
                threads: filteredThreads,
                selectedThread: $selectedThread,
                searchText: $searchText,
                onCompose: {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedThread = nil
                        pendingPhone = ""
                    }
                }
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            // Right panel — conversation detail or new conversation
            Group {
                if let phone = pendingPhone {
                    NewConversationPanel(
                        initialPhone: phone,
                        bridge: bridge,
                        onSent: {
                            // Called after sending — clear pending (new_sms event will refresh threads)
                            pendingPhone = nil
                        },
                        onCancel: {
                            withAnimation(.smooth(duration: 0.2)) { pendingPhone = nil }
                        }
                    )
                    .id("pending-\(phone)")
                } else if let thread = selectedThread {
                    ConversationPanel(
                        thread: thread,
                        messages: bridge.messages[thread.threadId] ?? [],
                        bridge: bridge
                    )
                    .id(thread.threadId)
                } else {
                    noSelectionPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { totalWidth in
            let maxAllowed = min(maxListWidth, totalWidth - minContentWidth - 20)
            if listWidth > maxAllowed { listWidth = max(minListWidth, maxAllowed) }
        }
        // When a thread is selected, dismiss compose panel and fetch messages
        .onChange(of: selectedThread?.threadId) { _, threadId in
            if let id = threadId {
                if pendingPhone != nil { pendingPhone = nil }
                bridge.fetchMessages(threadId: id)
                bridge.markRead(threadId: id)
            }
        }
        // Auto-select first thread once data loads (only when no pending compose)
        .onChange(of: bridge.threads) { _, threads in
            if selectedThread == nil, pendingPhone == nil, let first = threads.first {
                selectedThread = first
            }
        }
        // Navigate to thread when arriving from another tab (binding set before view appears)
        .onAppear { applyNavigateSMS(navigateSMSPhone) }
        .onChange(of: navigateSMSPhone) { _, phone in applyNavigateSMS(phone) }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView()
                    .controlSize(.regular)
                Text("Loading messages…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if bridge.threads.isEmpty {
                Image(systemName: "message")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.isConnected ? "No messages" : "Connect your phone to view messages")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "message")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select a conversation")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyNavigateSMS(_ phone: String?) {
        guard let phone, !phone.isEmpty else { return }
        navigateSMSPhone = nil   // consume so repeat taps re-trigger onChange
        let digits = phone.filter(\.isNumber)
        if let match = bridge.threads.first(where: { $0.contactPhone.filter(\.isNumber) == digits }) {
            withAnimation(.smooth(duration: 0.2)) {
                selectedThread = match
                pendingPhone = nil
            }
        } else {
            withAnimation(.smooth(duration: 0.2)) {
                selectedThread = nil
                pendingPhone = phone
            }
        }
    }
}
