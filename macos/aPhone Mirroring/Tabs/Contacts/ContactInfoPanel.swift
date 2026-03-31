// ContactInfoPanel.swift
// aPhone Mirroring
//
// Right panel of the Contacts tab. Identical layout to ContactDetailPanel: gradient background,
// large avatar, glass action buttons, and info sections (Organisation, Phone, Email, Birthday,
// Address, Website, Notes) in Color(white: 0.20) rounded cards.
//

import SwiftUI
import AppKit

// MARK: - ContactInfoPanel

struct ContactInfoPanel: View {
    let contact: BridgeContact
    let bridge: DataBridgeClient
    @State private var showMessageMenu = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(hue: contact.hue, saturation: 0.45, brightness: 0.28),
                    Color(white: 0.17)
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Avatar + name
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(hue: contact.hue, saturation: 0.5, brightness: 0.72))
                            Text(contact.initials)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 90, height: 90)
                        .shadow(
                            color: Color(hue: contact.hue, saturation: 0.6, brightness: 0.5).opacity(0.5),
                            radius: 20, x: 0, y: 8
                        )
                        Text(contact.displayName)
                            .font(.system(size: 22, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                    // Action buttons — Message (SMS) · Call · More
                    GlassEffectContainer(spacing: 16) {
                        HStack(spacing: 16) {
                            // Message → SMS in-app directly
                            VStack(spacing: 7) {
                                Button {
                                    let phone = contact.phoneNumbers.first ?? ""
                                    NotificationCenter.default.post(
                                        name: .navigateToSMS, object: nil,
                                        userInfo: ["phone": phone]
                                    )
                                } label: {
                                    Image(systemName: "message.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                Text("Message")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Call — directly initiates the call
                            VStack(spacing: 7) {
                                Button {
                                    if let phone = contact.phoneNumbers.first {
                                        bridge.placeCall(phone)
                                    }
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                Text("Call")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            // More — third-party app actions
                            VStack(spacing: 7) {
                                Button {
                                    let phone = contact.phoneNumbers.first ?? ""
                                    bridge.fetchContactApps(phone: phone, name: contact.displayName)
                                    showMessageMenu.toggle()
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 18, weight: .medium))
                                        .frame(width: 52, height: 52)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .popover(isPresented: $showMessageMenu, arrowEdge: .bottom) {
                                    AppActionsMenu(
                                        phone: contact.phoneNumbers.first ?? "",
                                        bridge: bridge,
                                        onDismiss: { showMessageMenu = false }
                                    )
                                }
                                Text("Other")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.bottom, 26)

                    // Organisation
                    if let org = contact.organization {
                        let detail = [contact.jobTitle, org].compactMap { $0 }.joined(separator: " · ")
                        infoSection(title: "Organisation") {
                            infoRow(icon: "building.2", value: detail)
                        }
                        .padding(.bottom, 12)
                    }

                    // Phone numbers — deduplicated by digits-only comparison
                    let dedupedPhones: [String] = {
                        var seen = Set<String>()
                        return contact.phoneNumbers.filter { seen.insert($0.filter(\.isNumber)).inserted }
                    }()
                    if !dedupedPhones.isEmpty {
                        infoSection(title: "Phone") {
                            ForEach(Array(dedupedPhones.enumerated()), id: \.offset) { idx, num in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRow(icon: "phone", value: num)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Emails — tappable to open a draft in the default mail app
                    if !contact.emails.isEmpty {
                        infoSection(title: "Email") {
                            ForEach(Array(contact.emails.enumerated()), id: \.offset) { (idx: Int, email: String) in
                                VStack(spacing: 0) {
                                    if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                    Button {
                                        if let url = URL(string: "mailto:\(email)") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        infoRow(icon: "envelope", value: email)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open in Mail")
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Birthday
                    if let bday = contact.birthday {
                        infoSection(title: "Birthday") {
                            infoRow(icon: "gift", value: bday)
                        }
                        .padding(.bottom, 12)
                    }

                    // Addresses
                    if !contact.addresses.isEmpty {
                        infoSection(title: "Address") {
                            ForEach(Array(contact.addresses.enumerated()), id: \.offset) { idx, addr in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRowMultiline(icon: "mappin", value: addr)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Websites
                    if !contact.websites.isEmpty {
                        infoSection(title: "Website") {
                            ForEach(Array(contact.websites.enumerated()), id: \.offset) { idx, url in
                                if idx > 0 { Divider().opacity(0.1).padding(.leading, 42) }
                                infoRow(icon: "globe", value: url)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Notes
                    if let notes = contact.notes {
                        infoSection(title: "Notes") {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .padding(.top, 1)
                                Text(notes)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .padding(.bottom, 16)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoSection<Content: View>(title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.20)))
        }
    }

    private func infoRow(icon: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func infoRowMultiline(icon: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
