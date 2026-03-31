// ContactsTabView.swift
// aPhone Mirroring
//
// Top-level Contacts tab layout: two-panel split (ContactListPanel left, ContactInfoPanel right).
// Shares sidebarWidth binding with Messages and Calls tabs.
//

import SwiftUI

// MARK: - ContactsTabView

struct ContactsTabView: View {
    @Binding var listWidth: CGFloat
    let bridge: DataBridgeClient
    @State private var selectedContact: BridgeContact? = nil
    @State private var searchText = ""

    private let minListWidth: CGFloat = 160
    private let maxListWidth: CGFloat = 340
    private let minContentWidth: CGFloat = 220

    private var filteredContacts: [BridgeContact] {
        guard !searchText.isEmpty else { return bridge.contacts }
        return bridge.contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ContactListPanel(
                contacts: filteredContacts,
                selectedContact: $selectedContact,
                searchText: $searchText
            )
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PanelResizeDivider(width: $listWidth, minWidth: minListWidth, maxWidth: maxListWidth)

            Group {
                if let contact = selectedContact {
                    ContactInfoPanel(contact: contact, bridge: bridge)
                        .id(contact.contactId)
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
        .onChange(of: bridge.contacts) { _, contacts in
            if selectedContact == nil, let first = contacts.first { selectedContact = first }
        }
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            if bridge.isLoading {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(bridge.contacts.isEmpty && !bridge.isConnected
                     ? "Connect your phone to view contacts"
                     : "Select a contact")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
