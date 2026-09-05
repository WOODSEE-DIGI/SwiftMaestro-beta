import SwiftUI

// MARK: - Suppliers Page

/// Supplier / vendor management. Suppliers are used by Bills and can have a
/// default expense account and payment terms.
struct SuppliersPage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @State private var editingSupplier: BooksSupplier?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(viewModel.suppliers) { supplier in
                SupplierRow(supplier: supplier, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { edit(supplier) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chatBackground)
        }
        .sheet(isPresented: $showEditor) {
            SupplierEditorSheet(
                viewModel: viewModel,
                supplier: editingSupplier ?? .blank,
                isPresented: $showEditor)
        }
    }

    private var header: some View {
        HStack {
            Text("Suppliers")
                .font(.headline)
            Spacer()
            Button {
                editingSupplier = .blank
                showEditor = true
            } label: {
                Label("New Supplier", systemImage: "plus")
            }
        }
        .padding()
        .background(theme.secondaryBackground)
    }

    private func edit(_ supplier: BooksSupplier) {
        editingSupplier = supplier
        showEditor = true
    }
}

private struct SupplierRow: View {
    let supplier: BooksSupplier
    let theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                BooksImageThumbnail(relativePath: supplier.imageURL, fallback: "building.2", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(supplier.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.chatText)
                    HStack(spacing: 12) {
                        if let email = supplier.email, !email.isEmpty {
                            Label(email, systemImage: "envelope")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let phone = supplier.phone, !phone.isEmpty {
                            Label(phone, systemImage: "phone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                RiskBadge(flag: RiskFlagService.shared.flag(for: supplier.name, taxID: supplier.taxNumber))
                if let terms = supplier.paymentTerms, !terms.isEmpty {
                    Text("\(terms) days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !supplier.addressBlock.isEmpty {
                Text(supplier.addressBlock)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Supplier editor

private struct SupplierEditorSheet: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var supplier: BooksSupplier
    @State private var showFlaggedConfirm = false
    private let isNew: Bool

    init(viewModel: BooksViewModel, supplier: BooksSupplier, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._supplier = State(initialValue: supplier)
        self.isNew = supplier.id == nil
    }

    private var flag: RiskFlag? {
        RiskFlagService.shared.flag(for: supplier.name, taxID: supplier.taxNumber)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Supplier" : "Edit Supplier")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") {
                    if isNew, flag != nil {
                        showFlaggedConfirm = true
                    } else {
                        save()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(supplier.name.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)
            .alert("Risk flag detected", isPresented: $showFlaggedConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Save anyway") { save() }
            } message: {
                if let flag {
                    Text("\(supplier.name) matches a \(flag.severity.displayName.lowercased()) flag: \(flag.reason). Do you want to save this supplier anyway?")
                }
            }

            if let flag {
                RiskFlagBanner(flag: flag)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            Form {
                TextField("Name", text: $supplier.name)
                TextField("Email", text: binding(for: $supplier.email))
                TextField("Phone", text: binding(for: $supplier.phone))
                TextField("Address line 1", text: binding(for: $supplier.addressLine1))
                TextField("Address line 2", text: binding(for: $supplier.addressLine2))
                TextField("City", text: binding(for: $supplier.city))
                TextField("Region", text: binding(for: $supplier.region))
                TextField("Postal code", text: binding(for: $supplier.postalCode))
                TextField("Country", text: binding(for: $supplier.country))
                TextField(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel, text: binding(for: $supplier.taxNumber))
                    .help(LocaleSettings.shared.primaryBusinessTaxIdentifier.placeholder)
                TextField("Payment terms (days)", text: binding(for: $supplier.paymentTerms))
                TextField("Default expense account code", text: binding(for: $supplier.defaultExpenseAccountCode))
                TextField("Notes", text: binding(for: $supplier.notes))
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 520)

            BooksImageAttachmentSection(
                relativePath: $supplier.imageURL,
                recordType: "supplier",
                recordID: supplier.id)
                .padding(.horizontal)
                .padding(.bottom)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func binding(for optional: Binding<String?>) -> Binding<String> {
        Binding(
            get: { optional.wrappedValue ?? "" },
            set: { optional.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func save() {
        Task {
            var mutable = supplier
            await viewModel.saveSupplier(&mutable)
            isPresented = false
        }
    }
}
