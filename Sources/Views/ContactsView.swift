import SwiftUI

// MARK: - Contacts view

/// Native Apple Contacts panel: search, list, create, and edit contacts.
/// Designed to work both as a sidebar panel and as a floating window.
struct ContactsView: View {
    @Environment(ContactsService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var query = ""
    @State private var contacts: [Contact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedContact: Contact?
    @State private var isEditing = false
    @State private var draft = Contact.empty

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search contacts", text: $query)
                    .textFieldStyle(.plain)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(8)
            .background(theme.secondaryBackground.opacity(0.5))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onSubmit { Task { await search() } }
            .onChange(of: query) { _, _ in
                Task { await search() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if let selectedContact, isEditing {
                contactEditor
                    .padding()
            } else if let selectedContact {
                contactDetail(selectedContact)
                    .padding()
            } else {
                List {
                    Section(header: Text("\(contacts.count) contacts")) {
                        ForEach(contacts) { contact in
                            Button {
                                selectedContact = contact
                                draft = contact
                            } label: {
                                contactRow(contact)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task {
            service.refreshStatus()
            if service.status == .authorized {
                await search()
            } else {
                await service.requestAccess()
                await search()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Contacts")
                .font(.headline)
            Spacer()
            Button {
                selectedContact = nil
                draft = Contact.empty
                isEditing = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                Task { await search() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Row

    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.2))
                Text(contact.initials)
                    .font(.caption.bold())
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                if !contact.organizationName.isEmpty {
                    Text(contact.organizationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let phone = contact.phoneNumbers.first {
                        Label(phone.value, systemImage: "phone")
                            .font(.caption2)
                    }
                    if let email = contact.emailAddresses.first {
                        Label(email.value, systemImage: "envelope")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Detail

    private func contactDetail(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.2))
                    Text(contact.initials)
                        .font(.title.bold())
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.title2.bold())
                    if !contact.organizationName.isEmpty {
                        Text(contact.organizationName)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if !contact.phoneNumbers.isEmpty {
                detailSection("Phone", icon: "phone") {
                    ForEach(contact.phoneNumbers, id: \.self) { phone in
                        HStack {
                            Text(phone.label ?? "mobile")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(phone.value)
                        }
                    }
                }
            }

            if !contact.emailAddresses.isEmpty {
                detailSection("Email", icon: "envelope") {
                    ForEach(contact.emailAddresses, id: \.self) { email in
                        HStack {
                            Text(email.label ?? "email")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(email.value)
                        }
                    }
                }
            }

            if !contact.addresses.isEmpty {
                detailSection("Address", icon: "location") {
                    ForEach(contact.addresses, id: \.self) { address in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(address.street)
                            Text("\(address.city), \(address.state) \(address.postalCode)")
                            Text(address.country)
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Close") {
                    selectedContact = nil
                }
                Spacer()
                Button("Edit") {
                    draft = contact
                    isEditing = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Editor

    private var contactEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedContact == nil ? "New Contact" : "Edit Contact")
                .font(.title2.bold())

            Group {
                TextField("First name", text: $draft.givenName)
                TextField("Last name", text: $draft.familyName)
                TextField("Organization", text: $draft.organizationName)
                TextField("Phone", text: phoneBinding)
                TextField("Email", text: emailBinding)
            }
            .textFieldStyle(.roundedBorder)

            Spacer()

            HStack {
                Button("Cancel") {
                    isEditing = false
                    selectedContact = nil
                }
                Spacer()
                Button("Save") {
                    Task { await saveDraft() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var phoneBinding: Binding<String> {
        Binding<String>(
            get: { draft.phoneNumbers.first?.value ?? "" },
            set: { draft = updatedDraft(phone: $0) }
        )
    }

    private var emailBinding: Binding<String> {
        Binding<String>(
            get: { draft.emailAddresses.first?.value ?? "" },
            set: { draft = updatedDraft(email: $0) }
        )
    }

    private func updatedDraft(phone: String? = nil, email: String? = nil) -> Contact {
        var copy = draft
        if let phone {
            copy = Contact(
                id: copy.id,
                givenName: copy.givenName,
                familyName: copy.familyName,
                organizationName: copy.organizationName,
                phoneNumbers: phone.isEmpty ? [] : [.init(label: nil, value: phone)],
                emailAddresses: copy.emailAddresses
            )
        }
        if let email {
            copy = Contact(
                id: copy.id,
                givenName: copy.givenName,
                familyName: copy.familyName,
                organizationName: copy.organizationName,
                phoneNumbers: copy.phoneNumbers,
                emailAddresses: email.isEmpty ? [] : [.init(label: nil, value: email)]
            )
        }
        return copy
    }

    private func saveDraft() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let id = draft.id, !id.isEmpty {
                try await service.updateContact(draft)
            } else {
                _ = try await service.createContact(draft)
            }
            isEditing = false
            selectedContact = nil
            await search()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Search

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            contacts = try await service.searchContacts(
                query: query.isEmpty ? nil : query,
                limit: 200
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
