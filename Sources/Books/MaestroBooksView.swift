import AppKit
import SwiftUI

// MARK: - MaestroBooks App
//
// Invoicing surface with three pages: Invoices, Clients, Products & Services.
// Publishes A4 invoice PDFs into MaestroDAM, exports Xero-compatible CSVs.
// Agents drive the same data via books_* tools.
struct MaestroBooksView: View {

    private enum BooksPage: String, CaseIterable, Identifiable {
        case invoices = "Invoices"
        case clients = "Clients"
        case products = "Products"
        case expenses = "Expenses"
        case template = "Template"
        case xero = "Xero"
        var id: String { rawValue }
    }

    @State private var viewModel = BooksViewModel()
    @State private var page: BooksPage = .invoices
    @State private var showNewInvoice = false
    @State private var newInvoiceClientID: Int64?
    @State private var showBusinessEditor = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if viewModel.isDemo {
                demoBanner
            }
            Divider()
            switch page {
            case .invoices:
                HStack(spacing: 0) {
                    invoiceList
                        .frame(width: 260)
                    Divider()
                    detailArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .clients:
                ClientsPage(viewModel: viewModel) { client in
                    newInvoiceClientID = client.id
                    showNewInvoice = true
                }
            case .products:
                ProductsPage(viewModel: viewModel)
            case .expenses:
                ExpensesPage(viewModel: viewModel)
            case .template:
                TemplatePage(viewModel: viewModel)
            case .xero:
                XeroPage(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.reload() }
        .sheet(isPresented: $showNewInvoice) {
            NewInvoiceSheet(
                viewModel: viewModel, isPresented: $showNewInvoice,
                preselectedClientID: newInvoiceClientID)
        }
        .sheet(isPresented: $showBusinessEditor) {
            BusinessEditorSheet(viewModel: viewModel, isPresented: $showBusinessEditor)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Page", selection: $page) {
                ForEach(BooksPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 480)

            Divider().frame(height: 18)

            if page == .invoices {
                Button {
                    newInvoiceClientID = nil
                    showNewInvoice = true
                } label: {
                    Label("New Invoice", systemImage: "plus")
                }

                Button {
                    Task {
                        do { _ = try await viewModel.publishSelectedInvoice() }
                        catch { viewModel.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Label("Publish PDF", systemImage: "doc.richtext")
                }
                .help("Render the A4 tax invoice PDF and file it in MaestroDAM")
                .disabled(viewModel.selectedInvoice == nil || viewModel.isPublishing)

                Button {
                    viewModel.exportForXero()
                } label: {
                    Label("Export for Xero", systemImage: "square.and.arrow.up")
                }
                .help("Write Xero-compatible invoice + contact import CSVs")
            }

            Spacer()

            if page == .invoices && !viewModel.overdueNumbers.isEmpty {
                Text("\(viewModel.overdueNumbers.count) overdue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                Task { await toggleDemo() }
            } label: {
                Label("Demo", systemImage: "theatermasks")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        viewModel.isDemo ? Color.purple : Color.secondary.opacity(0.15),
                        in: Capsule())
                    .foregroundStyle(viewModel.isDemo ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .help("Demo mode: sample data for screenshots & videos — "
                  + "your real books are never touched")

            Button { showBusinessEditor = true } label: {
                Image(systemName: "building.2")
            }
            .help("Business details (letterhead)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Demo mode

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks")
            Text("DEMO MODE — sample data only, nothing here is real. "
                 + "Your actual books are untouched.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Exit Demo") {
                Task { await toggleDemo() }
            }
            .buttonStyle(.bordered)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.purple)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.12))
    }

    private func toggleDemo() async {
        BooksDatabase.setDemoMode(!viewModel.isDemo)
        await viewModel.reload()
    }

    // MARK: Invoice list

    private var invoiceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invoices")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if viewModel.invoices.isEmpty {
                ContentUnavailableView(
                    "No Invoices",
                    systemImage: "doc.text",
                    description: Text("Create your first invoice — agents can too, via invoice_create."))
                .padding()
            } else {
                List(viewModel.invoices) { invoice in
                    Button {
                        Task { await viewModel.selectInvoice(invoice.id ?? -1) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(invoice.number)
                                    .font(.callout.weight(.medium))
                                Text(viewModel.clients.first { $0.id == invoice.clientID }?.name ?? "—")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            statusBadge(invoice.status)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        invoice.id == viewModel.selectedInvoice?.id
                            ? Color.accentColor : Color.primary)
                }
            }
        }
    }

    private func statusBadge(_ status: BooksInvoiceStatus) -> some View {
        let color: Color = switch status {
        case .draft: .secondary
        case .authorised: .orange
        case .paid: .green
        case .voided: .red
        }
        return Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: Detail

    @ViewBuilder
    private var detailArea: some View {
        if let invoice = viewModel.selectedInvoice {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(invoice.number)
                                .font(.title2.weight(.bold))
                            Text(viewModel.selectedClient?.name ?? "")
                                .foregroundStyle(.secondary)
                            Text("Issued \(invoice.issueDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let due = invoice.dueDate {
                                Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(
                                        viewModel.overdueNumbers.contains(invoice.number)
                                            ? .red : .secondary)
                            }
                        }
                        Spacer()
                        statusBadge(invoice.status)
                    }

                    // Actions
                    HStack(spacing: 10) {
                        if invoice.status == .draft {
                            Button("Mark Sent") { Task { await viewModel.setStatus(.authorised) } }
                                .buttonStyle(.borderedProminent)
                        }
                        if invoice.status == .authorised {
                            Button("Record Full Payment") {
                                Task { await viewModel.recordPayment(
                                    amount: viewModel.selectedTotals.total, method: "bank transfer") }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if invoice.status == .draft || invoice.status == .authorised {
                            Button("Void", role: .destructive) {
                                Task { await viewModel.setStatus(.voided) }
                            }
                        }
                        if invoice.status == .voided {
                            Button("Un-void") {
                                Task { await viewModel.setStatus(.draft) }
                            }
                        }
                        if let pdfPath = invoice.pdfPath {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: pdfPath)])
                            } label: {
                                Label("PDF", systemImage: "doc.richtext")
                            }
                        }
                    }

                    Divider()

                    // Items
                    Text("Line Items")
                        .font(.headline)
                    Grid(horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Qty").frame(width: 60, alignment: .trailing)
                            Text("Unit").frame(width: 80, alignment: .trailing)
                            Text("Amount").frame(width: 90, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(viewModel.selectedItems) { item in
                            GridRow {
                                Text(item.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                                Text(BooksMoney.plain(item.quantity))
                                    .frame(width: 60, alignment: .trailing)
                                Text(BooksMoney.plain(item.unitAmount))
                                    .frame(width: 80, alignment: .trailing)
                                Text(BooksMoney.plain(item.amount))
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                    }

                    // Totals
                    let totals = viewModel.selectedTotals
                    VStack(alignment: .trailing, spacing: 4) {
                        totalRow("Subtotal", totals.subtotal, invoice.currency, bold: false)
                        if invoice.taxRate > 0 {
                            totalRow("\(invoice.taxLabel) (\(invoice.taxRatePercentString)%)",
                                     totals.tax, invoice.currency, bold: false)
                        }
                        totalRow("Total", totals.total, invoice.currency, bold: true)
                        if totals.paid > 0 {
                            totalRow("Paid", -totals.paid, invoice.currency, bold: false)
                            totalRow("Balance due", totals.total - totals.paid, invoice.currency, bold: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    if let notes = invoice.notes, !notes.isEmpty {
                        Divider()
                        Text("Notes")
                            .font(.headline)
                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "MaestroBooks",
                systemImage: "dollarsign.doc",
                description: Text("Select an invoice, or create one — publish A4 tax invoice PDFs straight into MaestroDAM, export to Xero anytime."))
        }
    }

    private func totalRow(_ label: String, _ amount: Double, _ currency: String, bold: Bool) -> some View {
        HStack {
            Text(label)
                .font(bold ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(bold ? .primary : .secondary)
            Text(BooksMoney.format(amount, currency: currency))
                .font(bold ? .callout.weight(.bold) : .callout)
                .frame(width: 130, alignment: .trailing)
        }
    }
}

// MARK: - New Invoice Sheet

/// Create an invoice with structured line-item rows: client picker (or a new
/// client), per-row product picker / description / qty / price / discount %,
/// live totals, due days, notes. Agents keep the pipe-text format; both
/// funnel into the same createInvoice.
private struct NewInvoiceSheet: View {
    var viewModel: BooksViewModel
    @Binding var isPresented: Bool

    private static let newClientID: Int64 = -1

    @State private var selectedClientID: Int64 = newClientID
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var rows: [DraftItem] = [DraftItem()]
    @State private var dueDays = 14
    @State private var notes = ""
    @State private var error: String?
    @State private var showContactImport = false

    init(viewModel: BooksViewModel, isPresented: Binding<Bool>,
         preselectedClientID: Int64? = nil) {
        self.viewModel = viewModel
        _isPresented = isPresented
        _selectedClientID = State(initialValue: preselectedClientID ?? Self.newClientID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Invoice")
                .font(.title3.weight(.bold))

            HStack(spacing: 10) {
                Picker("Client", selection: $selectedClientID) {
                    Text("New client…").tag(Self.newClientID)
                    ForEach(viewModel.clients) { client in
                        Text(client.name).tag(client.id ?? -2)
                    }
                }
                .frame(width: 220)
                if selectedClientID == Self.newClientID {
                    TextField("Client name", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Email (optional)", text: $clientEmail)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Button {
                        showContactImport = true
                    } label: {
                        Label("Import", systemImage: "person.crop.circle.badge.plus")
                    }
                    .help("Import client details from macOS Contacts")
                }
                Spacer()
                Stepper("Due \(dueDays)d", value: $dueDays, in: 0...120)
            }

            // Line items — one structured row each.
            Grid(alignment: .centerFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Product").frame(width: 140, alignment: .leading)
                    Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Qty").frame(width: 48, alignment: .trailing)
                    Text("Price").frame(width: 76, alignment: .trailing)
                    Text("Disc%").frame(width: 52, alignment: .trailing)
                    Text("Amount").frame(width: 76, alignment: .trailing)
                    Color.clear.frame(width: 20, height: 1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach($rows) { $row in
                    GridRow {
                        Picker("", selection: $row.productID) {
                            Text("Custom").tag(Int64?.none)
                            ForEach(viewModel.products) { product in
                                Text(product.name).tag(product.id as Int64?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .onChange(of: row.productID) { _, newID in
                            guard let id = newID,
                                  let product = viewModel.products.first(where: { $0.id == id })
                            else { return }
                            $row.wrappedValue.description =
                                (product.details?.isEmpty == false ? product.details! : product.name)
                            $row.wrappedValue.unitPrice = BooksMoney.plain(product.unitPrice)
                        }

                        TextField("Description", text: $row.description)
                            .textFieldStyle(.roundedBorder)
                        TextField("1", text: $row.quantity)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        TextField("0.00", text: $row.unitPrice)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                            .multilineTextAlignment(.trailing)
                        TextField("0", text: $row.discount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                        Text(BooksMoney.plain(row.amount))
                            .frame(width: 76, alignment: .trailing)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(rows.count == 1)
                    }
                }
            }

            HStack {
                Button {
                    rows.append(DraftItem())
                } label: {
                    Label("Add item", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                let subtotal = rows.reduce(0) { $0 + $1.amount }
                let tax = subtotal * viewModel.seller.taxRate
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Subtotal \(BooksMoney.format(subtotal, currency: viewModel.seller.currency))")
                    if viewModel.seller.taxRate > 0 {
                        Text("\(viewModel.seller.taxLabel) \(BooksMoney.format(tax, currency: viewModel.seller.currency))")
                    }
                    Text("Total \(BooksMoney.format(subtotal + tax, currency: viewModel.seller.currency))")
                        .fontWeight(.bold)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            TextField("Notes (optional)", text: $notes)
                .textFieldStyle(.roundedBorder)

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create Invoice") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(resolvedClientName.isEmpty || validItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .sheet(isPresented: $showContactImport) {
            ContactPickerSheet(
                viewModel: viewModel, isPresented: $showContactImport
            ) { client in
                if let id = client.id { selectedClientID = id }
            }
        }
    }

    private var resolvedClientName: String {
        if selectedClientID == Self.newClientID {
            return clientName.trimmingCharacters(in: .whitespaces)
        }
        return viewModel.clients.first { $0.id == selectedClientID }?.name ?? ""
    }

    private var validItems: [(description: String, quantity: Double, unitAmount: Double, discount: Double)] {
        rows.compactMap(\.parsed)
    }

    private func create() {
        do {
            _ = try viewModel.createInvoice(
                clientName: resolvedClientName,
                clientEmail: clientEmail.isEmpty ? nil : clientEmail,
                items: validItems, dueDays: dueDays,
                notes: notes.isEmpty ? nil : notes)
            Task { await viewModel.reload() }
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One editable line-item row in the New Invoice sheet. String fields keep
/// typing natural; `parsed` validates + converts on the fly.
private struct DraftItem: Identifiable {
    let id = UUID()
    var productID: Int64?
    var description = ""
    var quantity = "1"
    var unitPrice = ""
    var discount = ""

    var parsed: (description: String, quantity: Double, unitAmount: Double, discount: Double)? {
        let desc = description.trimmingCharacters(in: .whitespaces)
        guard !desc.isEmpty,
              let qty = Double(quantity), qty > 0,
              let price = Double(unitPrice.replacingOccurrences(of: "$", with: ""))
        else { return nil }
        let disc = Double(discount.replacingOccurrences(of: "%", with: "")) ?? 0
        return (desc, qty, price, min(max(disc, 0), 100))
    }

    var amount: Double {
        guard let item = parsed else { return 0 }
        return item.quantity * item.unitAmount * (1 - item.discount / 100)
    }
}

// MARK: - Contact Picker Sheet

/// Search macOS Contacts and import one as an invoicing client. Two phases:
/// search/select, then choose WHICH name the client gets — person name or
/// organization (Contacts' org field is often used as a personal label/tag,
/// so the auto-pick is always user-confirmed). Email/phone/address come
/// across regardless of the chosen name.
private struct ContactPickerSheet: View {
    var viewModel: BooksViewModel
    @Binding var isPresented: Bool
    var onPicked: (BooksClient) -> Void

    @State private var contactsService = ContactsService()
    @State private var query = ""
    @State private var results: [Contact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    // Name/email/phone selection phase
    @State private var pendingContact: Contact?
    @State private var nameOptions: [String] = []
    @State private var nameChoice = ""
    @State private var emailOptions: [String] = []
    @State private var emailChoice = ""
    @State private var phoneOptions: [String] = []
    @State private var phoneChoice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from Contacts")
                .font(.title3.weight(.bold))

            if let pending = pendingContact {
                nameSelectionPhase(for: pending)
            } else {
                searchPhase
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .task { await search() }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await search()
            }
        }
    }

    // MARK: Phase 1 — search + select

    private var searchPhase: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search contacts", text: $query)
                .textFieldStyle(.roundedBorder)

            List(results) { contact in
                Button {
                    beginPick(contact)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.displayName)
                            Text([contact.organizationName,
                                  contact.emailAddresses.first?.value,
                                  contact.phoneNumbers.first?.value]
                                .compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: "  ·  "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)

            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
            }
        }
    }

    // MARK: Phase 2 — choose the client name

    @ViewBuilder
    private func nameSelectionPhase(for contact: Contact) -> some View {
        Text("Import \(contact.displayName) as:")
            .font(.headline)

        if nameOptions.count > 1 {
            Picker("Name", selection: $nameChoice) {
                ForEach(nameOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        TextField("Client name", text: $nameChoice)
            .textFieldStyle(.roundedBorder)

        if emailOptions.count > 1 {
            Picker("Email", selection: $emailChoice) {
                ForEach(emailOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        }

        if phoneOptions.count > 1 {
            Picker("Phone", selection: $phoneChoice) {
                ForEach(phoneOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        }

        // Everything else that comes across (single values + address).
        Text(summaryLine(for: contact))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)

        Spacer()

        HStack {
            Button("Back") { pendingContact = nil }
            Spacer()
            Button("Cancel") { isPresented = false }
            Button("Import Client") { Task { await confirmImport() } }
                .buttonStyle(.borderedProminent)
                .disabled(nameChoice.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Logic

    private func beginPick(_ contact: Contact) {
        pendingContact = contact
        errorMessage = nil
        // Person name first when both exist — org is often just a label/tag.
        var options: [String] = []
        if !contact.fullName.isEmpty { options.append(contact.fullName) }
        if !contact.organizationName.isEmpty, contact.organizationName != contact.fullName {
            options.append(contact.organizationName)
        }
        if options.isEmpty { options.append(contact.displayName) }
        nameOptions = options
        nameChoice = options[0]
        // Dedup while preserving card order; default = first on the card.
        emailOptions = contact.emailAddresses.map(\.value).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        emailChoice = emailOptions.first ?? ""
        phoneOptions = contact.phoneNumbers.map(\.value).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        phoneChoice = phoneOptions.first ?? ""
    }

    /// Single email/phone (no picker shown) + postal address summary.
    private func summaryLine(for contact: Contact) -> String {
        var parts: [String] = []
        if emailOptions.count == 1 { parts.append(emailOptions[0]) }
        if phoneOptions.count == 1 { parts.append(phoneOptions[0]) }
        if let address = contact.addresses.first {
            let text = [address.street, address.city, address.state, address.postalCode]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            if !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? "No contact details on this card"
            : parts.joined(separator: "  ·  ")
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await contactsService.searchContacts(query: query, limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmImport() async {
        guard let contact = pendingContact else { return }
        do {
            let client = try await viewModel.importContact(
                contact, nameOverride: nameChoice,
                emailOverride: emailChoice, phoneOverride: phoneChoice)
            onPicked(client)
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Xero Page

/// Xero connection + sync centre. Connect uses the PKCE flow (no client
/// secret in the binary); sync pushes contacts (matched by name) then
/// invoices (matched by number) and reports per-entity results.
private struct XeroPage: View {
    @Bindable var viewModel: BooksViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Xero")
                    .font(.title3.weight(.bold))

                if viewModel.isDemo {
                    // Never push demo data to a real Xero organisation.
                    HStack(spacing: 10) {
                        Image(systemName: "theatermasks")
                            .foregroundStyle(.purple)
                        Text("Xero is disabled in demo mode — exit demo to connect "
                             + "or sync your real books.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                } else if viewModel.xeroConnected {
                    connectedCard
                } else {
                    setupCard
                }

                if !viewModel.isDemo && viewModel.xeroConnected {
                    syncCard
                }

                if !viewModel.xeroReport.isEmpty {
                    reportCard
                }
            }
            .padding(20)
        }
    }

    // MARK: Setup (not connected)

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your Xero organisation")
                .font(.headline)
            Text("Your accountant gets live access to invoices and contacts "
                 + "straight from Xero. One-time setup:")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Go to developer.xero.com/myapps → New app")
                step(2, "Choose “Auth Code with PKCE” (no secret needed)")
                step(3, "Set the redirect URI to:")
                Text(XeroAPIClient.redirectURI)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.leading, 28)
                    .textSelection(.enabled)
                step(4, "Create the app and paste its Client ID below")
            }
            .font(.callout)

            HStack {
                TextField("Client ID", text: $viewModel.xeroClientID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                Button {
                    Task { await viewModel.connectXero() }
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.xeroClientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
        }
    }

    // MARK: Connected

    private var connectedCard: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.xeroTenantName ?? "Xero organisation")
                    .font(.headline)
                Text("Connected — tokens live in your Keychain, refresh is automatic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect") {
                Task { await viewModel.disconnectXero() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await viewModel.syncWithXero() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.xeroSyncing)
                if viewModel.xeroSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("Pushes new clients (matched by name) and invoices (matched by "
                 + "number). Already-synced items are skipped; voided invoices "
                 + "are never pushed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last sync report")
                .font(.headline)
            ForEach(Array(viewModel.xeroReport.enumerated()), id: \.offset) { _, result in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: result.ok ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(result.ok ? .green : .red)
                    Text(result.name)
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Template Page (invoice designer)
//
// Two modes over ONE template file:
//   Simple   — QuickBooks-style toggles + labels with a live sample preview;
//              regenerates the RTF template from BooksTemplateSettings.
//   Advanced — the RTF editor + Docs ribbon with raw {merge fields}.
// Publish always renders the template file; no file = built-in layout.
private struct TemplatePage: View {
    var viewModel: BooksViewModel

    @State private var docsVM = MaestroDocsViewModel()
    @State private var settings = BooksTemplateSettings.load()
    @State private var previewContent: NSAttributedString?
    @State private var applyTask: Task<Void, Never>?
    @State private var showResetConfirm = false
    @State private var showHelp = false
    @State private var templateReloadID = UUID()
    @AppStorage("maestrobooks.templateMode") private var mode = "simple"
    @AppStorage("maestrobooks.templateHelpDismissed") private var helpDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if !helpDismissed {
                guidanceBanner
                Divider()
            }
            modeBar
            Divider()
            if mode == "advanced" {
                advancedEditor
            } else {
                simpleEditor
            }
        }
        .task {
            openTemplate()
            refreshPreview()
        }
        .onChange(of: settings) { _, _ in simpleSettingsChanged() }
        .sheet(isPresented: $showHelp) { helpSheet }
        .confirmationDialog(
            "Reset the template to the default layout?",
            isPresented: $showResetConfirm
        ) {
            Button("Reset Template", role: .destructive) { resetTemplate() }
        }
    }

    // MARK: Guidance banner (dismissible)

    private var guidanceBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Design your invoice layout")
                    .font(.callout.weight(.semibold))
                Text("Simple: tick what appears and rename labels — the preview updates "
                     + "live. Advanced: edit the document directly; {fields} in curly braces "
                     + "are replaced with real invoice data when you publish. No template "
                     + "file at all = the built-in layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { helpDismissed = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Don't show this again")
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: Mode bar

    private var modeBar: some View {
        HStack(spacing: 10) {
            Text("Invoice Template")
                .font(.headline)
            Picker("Mode", selection: $mode) {
                Text("Simple").tag("simple")
                Text("Advanced").tag("advanced")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("How templates work + field reference")

            if mode == "advanced" {
                Menu {
                    ForEach(BooksTemplate.fieldGroups, id: \.group) { group in
                        Menu(group.group) {
                            ForEach(group.fields, id: \.self) { field in
                                Button(field) { insertField(field) }
                            }
                        }
                    }
                } label: {
                    Label("Insert Field", systemImage: "curlybraces")
                }

                Button {
                    docsVM.save()
                } label: {
                    Label("Save Template", systemImage: "square.and.arrow.down")
                }
                .disabled(!docsVM.canSave)
                .keyboardShortcut("s", modifiers: .command)
            }

            Button {
                showResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(mode == "advanced"
                  ? "Reset to the default template"
                  : "Restore default simple settings")

            Spacer()

            if mode == "advanced" && docsVM.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let status = docsVM.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Simple editor (toggles + labels + live preview)

    private var simpleEditor: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tick what appears on your invoices and rename the labels "
                         + "— the preview updates live. Publishing any invoice uses "
                         + "this layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("Title") {
                        TextField("Blank = automatic (TAX INVOICE / VAT INVOICE…)",
                                  text: $settings.invoiceTitle)
                            .textFieldStyle(.roundedBorder)
                            .padding(.top, 2)
                    }

                    GroupBox("Show on the invoice") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Business details (tax number, address)", isOn: $settings.showSellerDetails)
                            Toggle("Invoice number", isOn: $settings.showNumber)
                            Toggle("Issued & due dates", isOn: $settings.showDates)
                            Toggle("Status (Draft / Sent / Paid)", isOn: $settings.showStatus)
                            Toggle("Client address block", isOn: $settings.showClientDetails)
                            Toggle("Totals breakdown (subtotal, tax, paid)", isOn: $settings.showTotalsBreakdown)
                            Toggle("Notes section", isOn: $settings.showNotes)
                            Toggle("Payment instructions", isOn: $settings.showPaymentDetails)
                        }
                        .padding(.top, 2)
                    }

                    GroupBox("Labels") {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                Text("Client header").frame(width: 100, alignment: .trailing)
                                TextField("BILL TO", text: $settings.billToLabel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Notes header").frame(width: 100, alignment: .trailing)
                                TextField("NOTES", text: $settings.notesLabel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Payment header").frame(width: 100, alignment: .trailing)
                                TextField("PAYMENT", text: $settings.paymentLabel)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.top, 2)
                    }

                    Button("Restore Defaults") {
                        settings = BooksTemplateSettings()
                    }
                }
                .padding(16)
            }
            .frame(width: 350)

            Divider()

            VStack(spacing: 6) {
                TemplatePreviewView(content: previewContent)
                Text("Sample data preview — your business details fill in from Business settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Advanced editor (RTF + ribbon)

    private var advancedEditor: some View {
        VStack(spacing: 0) {
            DocsRibbon(viewModel: docsVM)
            Divider()
            TextDocumentEditor(
                richContent: docsVM.richContent,
                isPlain: false,
                isEditable: true,
                onChange: { docsVM.isDirty = true },
                ref: docsVM.textViewRef)
            .id(templateReloadID)
        }
    }

    // MARK: Help sheet (guidance + field reference)

    private var helpSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Invoice Templates")
                    .font(.title2.weight(.bold))
                Text("When you publish an invoice, MaestroBooks loads your template, "
                     + "replaces every {field} with the invoice's real data, and writes "
                     + "the PDF into MaestroDAM. Delete the template file to fall back "
                     + "to the built-in layout.")
                Text("Simple vs Advanced")
                    .font(.headline)
                Text("Simple builds the template from toggles — nothing to learn. "
                     + "Advanced edits the same template as a rich document. Changing "
                     + "a Simple setting later regenerates the template and replaces "
                     + "Advanced edits.")
                Text("Merge fields")
                    .font(.headline)
                ForEach(BooksTemplate.fieldGroups, id: \.group) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.group)
                            .font(.subheadline.weight(.semibold))
                        ForEach(group.fields, id: \.self) { field in
                            Text(field)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("{items} expands to the full items table. totals.tax_label becomes "
                     + "e.g. “GST (10%)”. Delete any field you don't want on the invoice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { showHelp = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 540)
        }
    }

    // MARK: Logic

    private func openTemplate() {
        do {
            let url = try BooksTemplate.ensureDefaultTemplate()
            docsVM.open(url)
            templateReloadID = UUID()
        } catch {
            docsVM.errorMessage = "Template failed to open: \(error.localizedDescription)"
        }
    }

    private func resetTemplate() {
        if mode == "advanced" {
            do {
                try BooksTemplate.resetToDefault()
                openTemplate()
            } catch {
                docsVM.errorMessage = "Reset failed: \(error.localizedDescription)"
            }
        } else {
            settings = BooksTemplateSettings()   // onChange applies + previews
        }
    }

    private func insertField(_ field: String) {
        docsVM.textViewRef.textView?.insertText(field)
        docsVM.isDirty = true
    }

    /// Simple edits: persist settings, debounce-regenerate the template
    /// file, then refresh the live preview through the real merge path.
    private func simpleSettingsChanged() {
        settings.save()
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                _ = try settings.applyToTemplateFile()
                refreshPreview()
            } catch {
                docsVM.errorMessage = "Template apply failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshPreview() {
        do {
            let sample = BooksTemplateSettings.sampleData(seller: viewModel.seller)
            previewContent = try InvoiceTemplateRenderer.mergedDocument(
                invoice: sample.invoice, client: sample.client,
                items: sample.items, payments: sample.payments,
                seller: viewModel.seller,
                templateURL: BooksTemplate.templateFileURL)
        } catch {
            previewContent = nil
        }
    }
}

/// Read-only paper preview of the merged sample invoice (white page on a
/// grey gutter, like the document viewers).
private struct TemplatePreviewView: NSViewRepresentable {
    let content: NSAttributedString?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 40, height: 40)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.9, alpha: 1)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let content, textView.string != content.string {
            textView.textStorage?.setAttributedString(content)
        }
    }
}

// MARK: - Expenses Page

/// Supplier bills: list + edit form + status flow. Pushes to Xero as ACCPAY
/// invoices (bills) during sync; suppliers become Xero contacts by usage.
private struct ExpensesPage: View {
    var viewModel: BooksViewModel

    @State private var search = ""
    @State private var draft: BooksExpense?
    @State private var showDeleteConfirm = false

    private var filtered: [BooksExpense] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return viewModel.expenses }
        return viewModel.expenses.filter {
            $0.supplier.lowercased().contains(query)
                || $0.expenseDescription.lowercased().contains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Expenses")
                        .font(.headline)
                    Spacer()
                    Button { newExpense() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New expense")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                List(filtered, id: \.id) { expense in
                    Button {
                        draft = expense
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.supplier)
                                Text(expense.expenseDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(BooksMoney.format(expense.total,
                                                       currency: expense.currency))
                                    .font(.caption)
                                Text(expense.status.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(statusColor(expense.status))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 280)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let current = draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.id == nil ? "New Expense"
                         : "\(current.supplier) — \(BooksMoney.format(current.total, currency: current.currency))")
                        .font(.title3.weight(.bold))

                    Form {
                        TextField("Supplier", text: stringBinding(\.supplier))
                        TextField("Description", text: stringBinding(\.expenseDescription))
                        TextField("Supplier invoice no. (optional)",
                                  text: optionalBinding(\.reference))
                        DatePicker("Date", selection: dateBinding,
                                   displayedComponents: .date)
                        TextField("Amount (ex tax)", text: subtotalBinding)
                        TextField("Tax rate %", text: taxRateBinding)
                        TextField("Account code", text: stringBinding(\.accountCode))
                        TextField("Notes (optional)", text: optionalBinding(\.notes))
                    }
                    .formStyle(.grouped)

                    // Status flow (Xero-verbatim statuses, same as invoices).
                    HStack(spacing: 10) {
                        if current.id != nil {
                            if current.status == .draft {
                                Button("Authorise") {
                                    Task { await viewModel.setExpenseStatus(current.id ?? -1, .authorised) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            if current.status == .authorised {
                                Button("Mark Paid") {
                                    Task { await viewModel.setExpenseStatus(current.id ?? -1, .paid) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            if current.status == .draft || current.status == .authorised {
                                Button("Void", role: .destructive) {
                                    Task { await viewModel.setExpenseStatus(current.id ?? -1, .voided) }
                                }
                            }
                            if current.status == .voided {
                                Button("Un-void") {
                                    Task { await viewModel.setExpenseStatus(current.id ?? -1, .draft) }
                                }
                            }
                        }
                        Spacer()
                        if current.id != nil && current.xeroID == nil {
                            Button("Delete", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                        Button(current.id == nil ? "Create Expense" : "Save") {
                            var expense = current
                            Task {
                                await viewModel.saveExpense(&expense)
                                draft = expense
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(current.supplier.trimmingCharacters(in: .whitespaces).isEmpty
                                  || current.expenseDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(20)
            }
            .confirmationDialog("Delete this expense?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    guard let id = current.id else { return }
                    Task {
                        await viewModel.deleteExpense(id: id)
                        draft = nil
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select an expense", systemImage: "creditcard",
                description: Text("Or add one with the + button. "
                                  + "Expenses sync to Xero as bills."))
        }
    }

    private func newExpense() {
        let now = Date()
        draft = BooksExpense(
            id: nil, supplier: "", expenseDescription: "", reference: nil,
            accountCode: viewModel.seller.defaultExpenseAccountCode,
            issueDate: now, statusRaw: BooksInvoiceStatus.draft.rawValue,
            currency: viewModel.seller.currency,
            taxRate: viewModel.seller.taxRate,
            taxType: viewModel.seller.expenseTaxType,
            subtotal: 0, notes: nil, xeroID: nil, createdAt: now, updatedAt: now)
    }

    private func statusColor(_ status: BooksInvoiceStatus) -> Color {
        switch status {
        case .draft: return .secondary
        case .authorised: return .blue
        case .paid: return .green
        case .voided: return .red
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<BooksExpense, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { draft?[keyPath: keyPath] = $0 })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<BooksExpense, String?>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                draft?[keyPath: keyPath] = trimmed.isEmpty ? nil : $0
            })
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft?.issueDate ?? Date() },
            set: { draft?.issueDate = $0 })
    }

    private var subtotalBinding: Binding<String> {
        Binding(
            get: {
                guard let draft, draft.subtotal != 0 else { return "" }
                return BooksMoney.plain(draft.subtotal)
            },
            set: {
                draft?.subtotal = Double($0.replacingOccurrences(of: "$", with: "")) ?? 0
            })
    }

    private var taxRateBinding: Binding<String> {
        Binding(
            get: {
                guard let draft else { return "" }
                return String(format: "%g", draft.taxRate * 100)
            },
            set: {
                if let value = Double($0.replacingOccurrences(of: "%", with: "")) {
                    draft?.taxRate = value / 100
                }
            })
    }
}

// MARK: - Clients Page

/// Client directory: searchable list + full edit form + the client's
/// invoices. Deletion is refused while the client has invoices (accounting
/// records keep their client snapshot forever).
private struct ClientsPage: View {
    var viewModel: BooksViewModel
    var onNewInvoice: (BooksClient) -> Void

    @State private var search = ""
    @State private var draft: BooksClient?
    @State private var showDeleteConfirm = false

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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Clients")
                        .font(.headline)
                    Spacer()
                    Button { draft = .blank } label: {
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
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.name)
                            Text([client.email, client.poCity]
                                .compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 260)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let current = draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(current.id == nil ? "New Client" : current.name)
                            .font(.title3.weight(.bold))
                        Spacer()
                        if current.id != nil,
                           let stored = viewModel.clients.first(where: { $0.id == current.id }) {
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
                        TextField("Tax number", text: optionalBinding(\.taxNumber))
                        TextField("Address", text: optionalBinding(\.poAddressLine1))
                        TextField("City", text: optionalBinding(\.poCity))
                        TextField("State / region", text: optionalBinding(\.poRegion))
                        TextField("Postcode", text: optionalBinding(\.poPostalCode))
                        TextField("Country", text: optionalBinding(\.poCountry))
                    }
                    .formStyle(.grouped)

                    HStack {
                        if current.id != nil {
                            Button("Delete", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                        Spacer()
                        Button(current.id == nil ? "Create Client" : "Save") {
                            var client = current
                            Task {
                                await viewModel.saveClient(&client)
                                draft = client
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(current.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let id = current.id {
                        let clientInvoices = viewModel.invoices(forClient: id)
                        if !clientInvoices.isEmpty {
                            Divider()
                            Text("Invoices")
                                .font(.headline)
                            ForEach(clientInvoices) { invoice in
                                HStack {
                                    Text(invoice.number)
                                    Text(invoice.status.displayName)
                                        .font(.caption)
                                        .foregroundStyle(statusColor(invoice.status))
                                    Spacer()
                                    Text(InvoicePDFRenderer.dateString(invoice.issueDate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .confirmationDialog("Delete this client?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    guard let id = current.id else { return }
                    Task {
                        await viewModel.deleteClient(id: id)
                        // Only clear the editor when the delete actually happened
                        // (it is refused while the client has invoices).
                        if !viewModel.clients.contains(where: { $0.id == id }) {
                            draft = nil
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a client", systemImage: "person.2",
                description: Text("Or add one with the + button."))
        }
    }

    private func statusColor(_ status: BooksInvoiceStatus) -> Color {
        switch status {
        case .draft: return .secondary
        case .authorised: return .blue
        case .paid: return .green
        case .voided: return .red
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<BooksClient, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { draft?[keyPath: keyPath] = $0 })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<BooksClient, String?>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                draft?[keyPath: keyPath] = trimmed.isEmpty ? nil : $0
            })
    }
}

// MARK: - Products Page

/// Price list as a full page: searchable product/service list + edit form.
/// Entries appear in the New Invoice sheet's per-row product picker.
private struct ProductsPage: View {
    var viewModel: BooksViewModel

    @State private var search = ""
    @State private var draft: BooksProduct?
    @State private var showDeleteConfirm = false

    private var filtered: [BooksProduct] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return viewModel.products }
        return viewModel.products.filter {
            $0.name.lowercased().contains(query)
                || ($0.details?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Products & Services")
                        .font(.headline)
                    Spacer()
                    Button {
                        draft = BooksProduct(
                            id: nil, name: "", details: nil, unitPrice: 0,
                            accountCode: nil, taxType: nil,
                            createdAt: Date(), updatedAt: Date())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New product / service")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                List(filtered, id: \.id) { product in
                    Button {
                        draft = product
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.name)
                                if let details = product.details, !details.isEmpty {
                                    Text(details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(BooksMoney.format(product.unitPrice,
                                                   currency: viewModel.seller.currency))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 260)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let current = draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.id == nil ? "New Product / Service" : current.name)
                        .font(.title3.weight(.bold))

                    Form {
                        TextField("Name", text: stringBinding(\.name))
                        TextField("Description (shown on invoices)",
                                  text: optionalBinding(\.details))
                        TextField("Unit price", text: priceBinding)
                        TextField("Item code (blank = auto)",
                                  text: optionalBinding(\.code))
                        TextField("Xero account code (optional)",
                                  text: optionalBinding(\.accountCode))
                    }
                    .formStyle(.grouped)

                    HStack {
                        if current.id != nil {
                            Button("Delete", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                        Spacer()
                        Button(current.id == nil ? "Add to Price List" : "Save") {
                            var product = current
                            product.name = product.name.trimmingCharacters(in: .whitespaces)
                            Task {
                                await viewModel.saveProduct(&product)
                                draft = product
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(current.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(20)
            }
            .confirmationDialog("Delete this product?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    guard let id = current.id else { return }
                    Task {
                        await viewModel.deleteProduct(id: id)
                        draft = nil
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a product or service", systemImage: "tag",
                description: Text("Or add one with the + button. "
                                  + "Products fill invoice rows with one click."))
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<BooksProduct, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { draft?[keyPath: keyPath] = $0 })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<BooksProduct, String?>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                draft?[keyPath: keyPath] = trimmed.isEmpty ? nil : $0
            })
    }

    private var priceBinding: Binding<String> {
        Binding(
            get: {
                guard let draft, draft.unitPrice != 0 else { return "" }
                return BooksMoney.plain(draft.unitPrice)
            },
            set: {
                draft?.unitPrice = Double($0.replacingOccurrences(of: "$", with: "")) ?? 0
            })
    }
}

// MARK: - Business Editor Sheet

/// Seller profile: letterhead identity + payment footer + default account
/// code (Xero Sales = 200). @Bindable gives the form bindings into the
/// @Observable view model.
private struct BusinessEditorSheet: View {
    @Bindable var viewModel: BooksViewModel
    @Binding var isPresented: Bool

    /// Tax rate edited as a whole percentage ("10" ⇄ 0.10).
    private var taxRatePercent: Binding<String> {
        Binding(
            get: { String(format: "%g", viewModel.seller.taxRate * 100) },
            set: { text in
                if let value = Double(text.replacingOccurrences(of: "%", with: "")) {
                    viewModel.seller.taxRate = value / 100
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Business Details")
                .font(.title3.weight(.bold))
            Text("Shown on invoice letterheads. Pick your currency — tax "
                 + "defaults follow it, then edit anything to suit your country.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField("Business name", text: $viewModel.seller.name)
                Picker("Currency", selection: $viewModel.seller.currency) {
                    ForEach(BooksSeller.commonCurrencies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Tax number", text: $viewModel.seller.abn)
                TextField("Address", text: $viewModel.seller.address)
                TextField("Email", text: $viewModel.seller.email)
                TextField("Phone", text: $viewModel.seller.phone)
                TextField("Default account code (Xero)", text: $viewModel.seller.defaultAccountCode)
            }

            Text("Tax (applied to new invoices; existing invoices keep their original rates)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Form {
                TextField("Tax name (GST / VAT / Sales Tax)", text: $viewModel.seller.taxLabel)
                TextField("Tax rate % (0 = no tax)", text: taxRatePercent)
                TextField("Tax number label", text: $viewModel.seller.taxRegistrationLabel)
                TextField("Xero tax type", text: $viewModel.seller.taxType)
                TextField("Xero expense tax type", text: $viewModel.seller.expenseTaxType)
                TextField("Expense account code", text: $viewModel.seller.defaultExpenseAccountCode)
                TextField("Invoice title (optional)", text: $viewModel.seller.invoiceTitle)
            }

            Text("Payment instructions (invoice footer)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.seller.paymentDetails)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        // Currency is the primary question — changing it refills the tax
        // fields with that country's defaults (still fully editable after).
        .onChange(of: viewModel.seller.currency) { _, newCode in
            let defaults = BooksSeller.taxDefaults(forCurrency: newCode)
            viewModel.seller.taxLabel = defaults.taxLabel
            viewModel.seller.taxRate = defaults.taxRate
            viewModel.seller.taxType = defaults.taxType
            viewModel.seller.expenseTaxType = defaults.expenseTaxType
            viewModel.seller.taxRegistrationLabel = defaults.registrationLabel
        }
    }
}
