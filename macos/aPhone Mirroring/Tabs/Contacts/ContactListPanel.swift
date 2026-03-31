// ContactListPanel.swift
// aPhone Mirroring
//
// Left panel of the Contacts tab: scrollable ContactRow list with hue-tinted avatars, names, and
// first phone numbers. Sidebar width shared via binding.
//

import SwiftUI

// MARK: - ContactListPanel

struct ContactListPanel: View {
    let contacts: [BridgeContact]
    @Binding var selectedContact: BridgeContact?
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
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(contacts) { contact in
                        ContactRow(
                            contact: contact,
                            isSelected: selectedContact?.id == contact.id
                        ) {
                            withAnimation(.smooth(duration: 0.2)) { selectedContact = contact }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

// MARK: - ContactRow

struct ContactRow: View {
    let contact: BridgeContact
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hue: contact.hue, saturation: 0.6, brightness: 0.75))
                    Text(contact.initials)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let phone = contact.phoneNumbers.first {
                        Text(phone)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
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
