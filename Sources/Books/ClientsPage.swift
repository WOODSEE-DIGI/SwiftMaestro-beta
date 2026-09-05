import AppKit
import SwiftUI

// MARK: - Clients Page

/// Client management and customer-intelligence page for MaestroBooks. There is
/// no separate CRM tab and no popup contact card — the client page itself is
/// the single place to view and edit everything about a customer.
struct ClientsPage: View {
    var viewModel: BooksViewModel
    var onNewInvoice: (BooksClient) -> Void

    @State private var search = ""
    @State private var draft: BooksClient?
    @State private var isEditing = false
    @State private var listWidth: CGFloat = 260

    private var filtered: [BooksClient] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return viewModel.clients }
        return viewModel.clients.filter {
            $0.name.lowercased().contains(query)
                || ($0.email?.lowercased().contains(query) ?? false)
                || ($0.poCity?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        ResizablePanelHost(axis: .horizontal, panes: [
            ResizablePane(id: "clientList", length: $listWidth, minLength: 200, maxLength: 500) { clientList },
            ResizablePane(id: "clientDetail", length: nil) { detailArea }
        ])
    }

    private var clientList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clients")
                    .font(.headline)
                Spacer()
                Button {
                    draft = .blank
                    isEditing = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New client")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            List(filtered, id: \.id) { client in
                Button {
                    draft = client
                    isEditing = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name)
                            Text([client.email, client.poCity]
                                .compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        RiskBadge(flag: RiskFlagService.shared.flag(for: client.name, taxID: client.taxNumber))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if let current = draft {
            if isEditing || current.id == nil {
                ClientEditor(
                    viewModel: viewModel,
                    client: current,
                    onNewInvoice: onNewInvoice,
                    onDone: { saved in
                        draft = saved
                        isEditing = saved.id == nil ? false : false
                    })
            } else {
                ClientDetailView(
                    viewModel: viewModel,
                    client: current,
                    onNewInvoice: onNewInvoice,
                    onEdit: { isEditing = true })
            }
        } else {
            ContentUnavailableView(
                "Select a client", systemImage: "person.2",
                description: Text("Or add one with the + button."))
        }
    }
}

// MARK: - Client Editor

private struct ClientEditor: View {
    let viewModel: BooksViewModel
    let client: BooksClient
    let onNewInvoice: (BooksClient) -> Void
    let onDone: (BooksClient) -> Void

    @Environment(ThemeStore.self) private var theme
    @State private var draft: BooksClient
    @State private var showDeleteConfirm = false
    @State private var flaggedConfirm: BooksClient?
    @State private var customFieldRows: [CustomField]

    init(viewModel: BooksViewModel, client: BooksClient, onNewInvoice: @escaping (BooksClient) -> Void, onDone: @escaping (BooksClient) -> Void) {
        self.viewModel = viewModel
        self.client = client
        self.onNewInvoice = onNewInvoice
        self.onDone = onDone
        _draft = State(initialValue: client)
        _customFieldRows = State(initialValue: (client.customFields ?? [:])
            .map { CustomField(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(draft.id == nil ? "New Client" : "Edit Client")
                        .font(.title3.weight(.bold))
                    Spacer()
                    if draft.id != nil,
                       let stored = viewModel.clients.first(where: { $0.id == draft.id }) {
                        Button {
                            onNewInvoice(stored)
                        } label: {
                            Label("New Invoice", systemImage: "plus")
                        }
                    }
                }

                Form {
                    TextField("Name", text: stringBinding(\.name))
                    TextField("Email", text: optionalBinding(\.email))
                    TextField("Phone", text: optionalBinding(\.phone))
                    TextField(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel, text: optionalBinding(\.taxNumber))
                        .help(LocaleSettings.shared.primaryBusinessTaxIdentifier.placeholder)
                    Toggle("Allow p2p blacklist reporting for this client", isOn: boolBinding(\.reportToBlacklist))
                        .help("When off, no unpaid invoices for this client can be reported to the SwiftMaestro p2p network.")
                    TextField("Address", text: optionalBinding(\.poAddressLine1))
                    TextField("City", text: optionalBinding(\.poCity))
                    TextField("State / region", text: optionalBinding(\.poRegion))
                    TextField("Postcode", text: optionalBinding(\.poPostalCode))
                    TextField("Country", text: optionalBinding(\.poCountry))
                }
                .formStyle(.grouped)

                customFieldsSection

                HStack {
                    if draft.id != nil {
                        Button("Delete", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                    Spacer()
                    Button("Cancel") {
                        if draft.id == nil {
                            onDone(client)
                        } else {
                            onDone(client)
                        }
                    }
                    .buttonStyle(.borderless)
                    Button(draft.id == nil ? "Create Client" : "Save") {
                        if draft.id == nil,
                           RiskFlagService.shared.flag(for: draft.name, taxID: draft.taxNumber) != nil {
                            flaggedConfirm = draft
                        } else {
                            save()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .alert("Risk flag detected", isPresented: Binding(
                        get: { flaggedConfirm != nil },
                        set: { if !$0 { flaggedConfirm = nil } }
                    ), presenting: flaggedConfirm) { _ in
                        Button("Cancel", role: .cancel) { flaggedConfirm = nil }
                        Button("Save anyway") {
                            flaggedConfirm = nil
                            save()
                        }
                    } message: { client in
                        if let flag = RiskFlagService.shared.flag(for: client.name, taxID: client.taxNumber) {
                            Text("\(client.name) matches a \(flag.severity.displayName.lowercased()) flag: \(flag.reason). Do you want to save this client anyway?")
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(theme.chatBackground)
        .confirmationDialog("Delete this client?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                guard let id = draft.id else { return }
                Task {
                    await viewModel.deleteClient(id: id)
                    if !viewModel.clients.contains(where: { $0.id == id }) {
                        onDone(draft)
                    }
                }
            }
        }
    }

    private func save() {
        var copy = draft
        copy.customFields = Dictionary(
            uniqueKeysWithValues: customFieldRows
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
        )
        if copy.customFields?.isEmpty == true {
            copy.customFields = nil
        }
        Task {
            _ = await viewModel.saveClient(&copy)
            onDone(copy)
        }
    }

    private struct CustomField: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private var customFieldsSection: some View {
        GroupBox(label: Text("Custom Fields").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                if !customFieldRows.isEmpty {
                    ForEach($customFieldRows) { $row in
                        HStack(spacing: 8) {
                            TextField("Key", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                            TextField("Value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                customFieldRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("No custom fields. Add labels like Website, Referrer, UEN, etc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    customFieldRows.append(CustomField(key: "", value: ""))
                } label: {
                    Label("Add Field", systemImage: "plus")
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<BooksClient, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<BooksClient, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : $0
            })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<BooksClient, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }
}

// MARK: - Client Detail View

private struct ClientDetailView: View {
    let viewModel: BooksViewModel
    let client: BooksClient
    let onNewInvoice: (BooksClient) -> Void
    let onEdit: () -> Void

    @Environment(ThemeStore.self) private var theme
    @State private var profile: CRMContactCardProfile?
    @State private var activityContact: CRMActivityContact?
    @State private var avatarImage: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                if let flag = RiskFlagService.shared.flag(for: client.name, taxID: client.taxNumber) {
                    RiskFlagBanner(flag: flag)
                }

                HStack(alignment: .top, spacing: 16) {
                    contactSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                    addressSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                customFieldsSection

                if profile?.abnVerification != nil || profile?.osintCheck != nil {
                    verificationSection
                }

                if !clientInvoices.isEmpty {
                    invoicesSection
                }

                if let profile, !profile.assets.isEmpty {
                    assetsSection(profile: profile)
                }

                if let profile, !profile.activities.isEmpty {
                    activitiesSection(profile: profile)
                }

                if profile?.lastEmail != nil || profile?.lastWhatsApp != nil {
                    lastContactSection
                }

                if let profile, !profile.opportunities.isEmpty {
                    opportunitiesSection(profile: profile)
                }
            }
            .padding(20)
        }
        .background(theme.chatBackground)
        .task(id: client.id) {
            profile = await CRMContactCardService.shared.profile(for: client)
            loadAvatar()
        }
        .sheet(item: $activityContact) { contact in
            CRMActivityEditor(
                viewModel: viewModel,
                activity: BooksCRMActivity.blankFor(contactKind: contact.kind, contactID: contact.contactID),
                contactName: contact.name,
                isPresented: Binding(
                    get: { activityContact != nil },
                    set: { if !$0 { activityContact = nil } }
                )
            )
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                Text(client.name)
                    .font(.title2.bold())
                    .foregroundStyle(theme.chatText)
                if let company = profile?.company, !company.isEmpty {
                    Text(company)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "person.text.rectangle")
                        .font(.caption2)
                    Text("Client")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accent.opacity(0.15))
                .foregroundStyle(theme.accent)
                .clipShape(Capsule())

                HStack(spacing: 8) {
                    if let email = client.email, !email.isEmpty {
                        Button {
                            NSWorkspace.shared.open(URL(string: "mailto:\(email)")!)
                        } label: {
                            Label("Email", systemImage: "envelope")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let phone = client.phone, !phone.isEmpty {
                        Button {
                            let cleaned = phone.filter { $0.isNumber || $0 == "+" }
                            if let url = URL(string: "tel:\(cleaned)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Call", systemImage: "phone")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button {
                        onNewInvoice(client)
                    } label: {
                        Label("Invoice", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        activityContact = CRMActivityContact(kind: "client", contactID: client.id ?? 0, name: client.name)
                    } label: {
                        Label("Activity", systemImage: "note.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    private var customFieldsSection: some View {
        Group {
            if let fields = client.customFields, !fields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Fields")
                        .font(.headline)
                        .foregroundStyle(theme.chatText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], alignment: .leading, spacing: 8) {
                        ForEach(Array(fields.keys.sorted()), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(fields[key] ?? "")
                                    .font(.body)
                                    .foregroundStyle(theme.chatText)
                                    .textSelection(.enabled)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.secondaryBackground)
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(theme.accent.opacity(0.2))
            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.accent)
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(theme.accent.opacity(0.5))
                    .offset(y: 28)
            }
        }
        .frame(width: 96, height: 96)
        .help("Logo / headshot — click to choose")
        .contentShape(Circle())
        .onTapGesture { chooseAvatar() }
        .contextMenu {
            Button {
                chooseAvatar()
            } label: {
                Label("Choose Image…", systemImage: "photo")
            }
            if avatarImage != nil {
                Button {
                    ClientAvatarStore.clearAvatar(forClientID: client.id ?? 0)
                    avatarImage = nil
                } label: {
                    Label("Clear Image", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func loadAvatar() {
        guard let url = ClientAvatarStore.avatarURL(forClientID: client.id ?? 0) else {
            avatarImage = nil
            return
        }
        avatarImage = NSImage(contentsOf: url)
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .tiff, .gif, .heic]
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            guard result == .OK, let url = panel.url else { return }
            if let dest = ClientAvatarStore.setAvatar(forClientID: self.client.id ?? 0, from: url) {
                self.avatarImage = NSImage(contentsOf: dest)
            }
        }
    }

    private var initials: String {
        let parts = client.name.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .prefix(2)
        return parts.compactMap { $0.first?.uppercased() }.joined()
    }

    private var contactSection: some View {
        GroupBox("Contact") {
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Email", value: client.email)
                DetailRow(label: "Phone", value: client.phone)
                DetailRow(label: LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel, value: client.taxNumber)
                DetailRow(label: "Country", value: client.poCountry)
            }
        }
    }

    private var addressSection: some View {
        GroupBox("Address") {
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Street", value: client.poAddressLine1)
                DetailRow(label: "City", value: client.poCity)
                DetailRow(label: "State / region", value: client.poRegion)
                DetailRow(label: "Postcode", value: client.poPostalCode)
            }
        }
    }

    private var verificationSection: some View {
        GroupBox("Verification & Intelligence") {
            VStack(alignment: .leading, spacing: 8) {
                if let abn = profile?.abnVerification {
                    ABNVerificationRow(result: abn)
                }
                if let osint = profile?.osintCheck {
                    OSINTCheckRow(result: osint)
                }
            }
        }
    }

    private var invoicesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Invoices")
                        .font(.headline)
                    Spacer()
                    let overdue = clientInvoices.filter { isOverdue($0) }.count
                    if overdue > 0 {
                        Label("\(overdue) overdue", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                ForEach(clientInvoices) { invoice in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invoice.number)
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                Text(invoice.status.displayName)
                                    .font(.caption)
                                    .foregroundStyle(statusColor(invoice.status))
                                if isOverdue(invoice) {
                                    Text("Overdue")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.red.opacity(0.15))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        Spacer()
                        Text(totalFor(invoice))
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var clientInvoices: [BooksInvoice] {
        guard let id = client.id else { return [] }
        return viewModel.invoices(forClient: id)
    }

    private func isOverdue(_ invoice: BooksInvoice) -> Bool {
        invoice.status == .authorised && (invoice.dueDate ?? .distantFuture) < Date()
    }

    private func totalFor(_ invoice: BooksInvoice) -> String {
        guard let id = invoice.id else { return "—" }
        do {
            let items = try BooksDatabase.shared.lineItems(invoiceID: id)
            let subtotal = items.reduce(0) { $0 + ($1.quantity * $1.unitAmount * (1 - $1.discount / 100)) }
            let total = subtotal + (subtotal * invoice.taxRate)
            return BooksMoney.format(total, currency: invoice.currency)
        } catch {
            return "—"
        }
    }

    private func statusColor(_ status: BooksInvoiceStatus) -> Color {
        switch status {
        case .draft: return .secondary
        case .authorised: return .orange
        case .paid: return .green
        case .voided: return .red
        }
    }

    private func assetsSection(profile: CRMContactCardProfile) -> some View {
        GroupBox("Assets") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120))], spacing: 10) {
                ForEach(profile.assets) { asset in
                    CRMAssetThumbnail(asset: asset)
                }
            }
        }
    }

    private func activitiesSection(profile: CRMContactCardProfile) -> some View {
        GroupBox("Activity Timeline") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(profile.activities.prefix(5)) { activity in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: activity.kind.icon)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.subject)
                                .font(.subheadline.weight(.medium))
                            if let notes = activity.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 8) {
                                if let completed = activity.completedDate {
                                    Text("Completed \(completed.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else if let due = activity.dueDate {
                                    Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var lastContactSection: some View {
        GroupBox("Last Contact") {
            VStack(alignment: .leading, spacing: 8) {
                if let email = profile?.lastEmail {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mail: \(email.subject)")
                            .font(.subheadline.weight(.medium))
                        Text("From \(email.sender) · \(email.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let whatsapp = profile?.lastWhatsApp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WhatsApp: \(whatsapp.content)")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        Text("From \(whatsapp.sender) · \(whatsapp.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func opportunitiesSection(profile: CRMContactCardProfile) -> some View {
        GroupBox("Opportunities") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.opportunities) { opp in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opp.title)
                                .font(.subheadline.weight(.medium))
                            Text(opp.stage.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let value = opp.value {
                            Text(BooksMoney.format(value, currency: opp.currency))
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared helpers

private struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .fontWeight(.medium)
        }
    }
}

private struct ABNVerificationRow: View {
    let result: ABNVerificationResult

    var body: some View {
        HStack {
            Text("ABN verification")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: result.isVerified ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .foregroundStyle(result.isVerified ? .green : .orange)
                Text(result.isVerified ? "Verified" : "Unverified")
                    .fontWeight(.medium)
                    .foregroundStyle(result.isVerified ? .green : .orange)
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        if result.isVerified {
            let entity = result.entityName ?? "Unknown entity"
            return "Verified with \(result.source.displayName). \(entity)"
        } else {
            return "Could not verify ABN: \(result.errorMessage ?? "Unknown")"
        }
    }
}

private struct OSINTCheckRow: View {
    let result: OSINTBackgroundCheckResult

    var body: some View {
        HStack {
            Text("OSINT check")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .foregroundStyle(color)
                Text(statusText)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
            }
            .help(result.message)
        }
    }

    private var iconName: String {
        switch result.status {
        case .found: return "binoculars.fill"
        case .notFound: return "binoculars"
        case .notConfigured, .skipped: return "lock.open"
        case .rateLimited: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch result.status {
        case .found: return .blue
        case .notFound, .skipped: return .secondary
        case .notConfigured, .rateLimited: return .orange
        case .error: return .red
        }
    }

    private var statusText: String {
        switch result.status {
        case .found: return "\(result.profiles.count) found"
        case .notFound: return "None found"
        case .notConfigured: return "Not configured"
        case .skipped: return "Skipped"
        case .rateLimited: return "Rate limited"
        case .error: return "Error"
        }
    }
}

private struct CRMAssetThumbnail: View {
    let asset: CRMContactCardProfile.AssetSummary
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: asset.isImage ? "photo" : "doc")
                            .foregroundStyle(.secondary)
                    )
            }
            Text(asset.filename)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear {
            loadImage()
        }
        .contextMenu {
            Button {
                NotificationCenter.default.post(
                    name: .openInMaestroDAM,
                    object: nil,
                    userInfo: ["path": asset.path])
            } label: {
                Label("Open in MaestroDAM", systemImage: "photo.stack")
            }
            Button {
                NotificationCenter.default.post(
                    name: .sendToMaestroDB,
                    object: nil,
                    userInfo: ["path": asset.path])
            } label: {
                Label("Send to MaestroDB", systemImage: "tablecells")
            }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }

    private func loadImage() {
        guard asset.isImage else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOfFile: asset.path)
            DispatchQueue.main.async {
                self.image = img
            }
        }
    }
}

