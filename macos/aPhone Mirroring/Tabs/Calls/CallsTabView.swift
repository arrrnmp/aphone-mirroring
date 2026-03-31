// CallsTabView.swift
// aPhone Mirroring
//
// Top-level Calls tab layout: two-panel split (CallListPanel left, ContactDetailPanel right).
// Auto-selects first call on load. Shares sidebarWidth binding with Messages and Contacts tabs
// via ContentPanelView.
//

import SwiftUI

// MARK: - CallsTabView

struct CallsTabView: View {
    @Binding var listWidth: CGFloat
    let bridge: DataBridgeClient
    @State private var selectedCall: BridgeCall? = nil
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredCalls: [BridgeCall] {
        guard !searchText.isEmpty else { return bridge.calls }
        return bridge.calls.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            CallListPanel(
                calls: filteredCalls,
                selectedCall: $selectedCall,
                searchText: $searchText
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            Group {
                if let call = selectedCall {
                    ContactDetailPanel(call: call, allCalls: bridge.calls, bridge: bridge)
                        .id(call.callId)
                } else {
                    noSelectionView
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
        .onChange(of: bridge.calls) { _, calls in
            if selectedCall == nil, let first = calls.first { selectedCall = first }
        }
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "phone")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.calls.isEmpty && !bridge.isConnected
                     ? "Connect your phone to view calls"
                     : "Select a contact")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
