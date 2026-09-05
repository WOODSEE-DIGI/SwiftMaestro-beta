import SwiftUI

// MARK: - Bills Page

/// Supplier bills (ACCPAY). Lists bills, shows status, and supports creating
/// new draft bills from a supplier.
struct BillsPage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @State private var showNewBill = false
    @State private var selectedBill: BooksBill?
    @State private var listWidth: CGFloat = 280

    var body: some View {
        ResizablePanelHost(axis: .horizontal, panes: [
            ResizablePane(id: "billList", length: $listWidth, minLength: 200, maxLength: 500) { billList },
            ResizablePane(id: "billDetail", length: nil) { detailArea }
        ])
        .sheet(isPresented: $showNewBill) {
            NewBillSheet(viewModel: viewModel, isPresented: $showNewBill)
        }
    }

    private var billList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bills")
                    .font(.headline)
                Spacer()
                Button {
                    showNewBill = true
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
            .padding()
            .background(theme.secondaryBackground)

            List(viewModel.bills) { bill in
                BillRow(bill: bill, supplierName: supplierName(for: bill), theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBill = bill }
                    .background(selectedBill?.id == bill.id ? theme.accent.opacity(0.15) : Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chatBackground)
        }
    }

    private var detailArea: some View {
        Group {
            if let bill = selectedBill {
                BillDetail(viewModel: viewModel, bill: bill, supplierName: supplierName(for: bill))
            } else {
                ContentUnavailableView(
                    "No Bill Selected",
                    systemImage: "doc.text",
                    description: Text("Select a bill or create a new one."))
            }
        }
        .background(theme.chatBackground)
    }

    private func supplierName(for bill: BooksBill) -> String {
        viewModel.suppliers.first(where: { $0.id == bill.supplierID })?.name ?? "Unknown supplier"
    }
}

private struct BillRow: View {
    let bill: BooksBill
    let supplierName: String
    let theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                BooksImageThumbnail(relativePath: bill.imageURL, fallback: "doc.text.image", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.number)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.chatText)
                    Text(supplierName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(status: bill.status)
            }
            HStack {
                Text(bill.issueDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct StatusBadge: View {
    let status: BooksBillStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .draft: return .secondary
        case .awaitingPayment: return .orange
        case .paid: return .green
        case .voided: return .red
        }
    }
}

private struct BillDetail: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    let bill: BooksBill
    let supplierName: String
    @State private var lineItems: [BooksBillLineItem] = []

    private var subtotal: Double { lineItems.reduce(0) { $0 + $1.amount } }
    private var tax: Double { subtotal * bill.taxRate }
    private var total: Double { subtotal + tax }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bill.number)
                            .font(.title2.bold())
                        Text(supplierName)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusBadge(status: bill.status)
                        Text(bill.issueDate, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                if lineItems.isEmpty {
                    Text("No line items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lineItems) { item in
                            HStack {
                                Text(item.description)
                                    .foregroundStyle(theme.chatText)
                                Spacer()
                                Text(item.amount, format: .currency(code: bill.currency))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.chatText)
                            }
                        }
                        Divider()
                        HStack {
                            Text("Total")
                                .font(.headline)
                            Spacer()
                            Text(total, format: .currency(code: bill.currency))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(theme.chatText)
                        }
                    }
                }

                let billID = bill.id
                let currentImageURL = bill.imageURL
                BooksImageAttachmentSection(
                    relativePath: Binding<String?>(
                        get: { currentImageURL },
                        set: { newValue in
                            // Bill detail is read-only for the model passed in;
                            // update via the database and refresh the view model.
                            guard let id = billID else { return }
                            Task {
                                try? await BooksDatabase.shared.dbQueue.write { db in
                                    try db.execute(
                                        sql: "UPDATE bills SET image_url = ?, updated_at = ? WHERE id = ?",
                                        arguments: [newValue, Date().timeIntervalSince1970, id])
                                }
                                await viewModel.reload()
                            }
                        }),
                    recordType: "bill",
                    recordID: billID)

                if let notes = bill.notes, !notes.isEmpty {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .foregroundStyle(theme.chatText)
                }

                HStack {
                    if bill.status != .paid && bill.status != .voided {
                        Button("Mark Awaiting Payment") {
                            Task { await viewModel.setBillStatus(bill.id ?? 0, .awaitingPayment) }
                        }
                        Button("Mark Paid") {
                            Task { await viewModel.setBillStatus(bill.id ?? 0, .paid) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        if let id = bill.id {
                            Task { await viewModel.deleteBill(id: id) }
                        }
                    }
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
        .task {
            if let id = bill.id {
                lineItems = (try? await Task { @MainActor in
                    try BooksDatabase.shared.billLineItems(billID: id)
                }.value) ?? []
            }
        }
    }
}

// MARK: - New bill sheet

private struct NewBillSheet: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var supplierName = ""
    @State private var dueDays = 30
    @State private var notes = ""
    @State private var items: [BillItemForm] = [BillItemForm()]
    @State private var imagePath: String?
    @State private var scanResult: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Bill")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(supplierName.isEmpty || items.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)

            Form {
                TextField("Supplier name", text: $supplierName)
                TextField("Due in (days)", value: $dueDays, format: .number)
                TextField("Notes", text: $notes)

                BooksImageAttachmentSection(
                    relativePath: $imagePath,
                    recordType: "bill",
                    recordID: nil,
                    onImageSelected: { _ in
                        // Vision Proxy scan result for new bills is captured
                        // via notification and surfaced in scanResult.
                    })
                .onReceive(NotificationCenter.default.publisher(for: .booksReceiptScanned)) { notification in
                    scanResult = notification.userInfo?["ocrText"] as? String
                }

                Section("Line items") {
                    ForEach($items) { $item in
                        HStack(spacing: 8) {
                            TextField("Description", text: $item.description)
                                .frame(minWidth: 200)
                            TextField("Qty", value: $item.quantity, format: .number)
                                .frame(width: 60)
                            TextField("Amount", value: $item.unitAmount, format: .number)
                                .frame(width: 80)
                        }
                    }
                    Button {
                        items.append(BillItemForm())
                    } label: {
                        Label("Add line", systemImage: "plus")
                    }
                }
            }
            .padding()
            .frame(minWidth: 480, idealWidth: 640)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func create() {
        let tuples = items.map {
            (description: $0.description, quantity: $0.quantity, unitAmount: $0.unitAmount, discount: 0.0)
        }
        do {
            var bill = try viewModel.createBill(
                supplierName: supplierName, items: tuples,
                dueDays: dueDays, notes: notes.isEmpty ? nil : notes)
            if let imagePath {
                bill.imageURL = imagePath
                let billID = bill.id
                Task {
                    try? await BooksDatabase.shared.dbQueue.write { db in
                        try db.execute(
                            sql: "UPDATE bills SET image_url = ?, updated_at = ? WHERE id = ?",
                            arguments: [imagePath, Date().timeIntervalSince1970, billID ?? 0])
                    }
                    await viewModel.reload()
                }
            }
            isPresented = false
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct BillItemForm: Identifiable {
    let id = UUID()
    var description = ""
    var quantity: Double = 1
    var unitAmount: Double = 0
}
