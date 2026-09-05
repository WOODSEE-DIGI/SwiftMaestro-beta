import SwiftUI

// MARK: - Accounts Page

/// Chart of Accounts management. Lists GL accounts by code and lets the user
/// add, edit, and delete accounts. Bank accounts are flagged for the Bank page.
struct AccountsPage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @State private var editingAccount: BooksAccount?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(BooksAccountType.allCases) { type in
                    Section {
                        let typeAccounts = viewModel.accounts.filter { $0.type == type }
                        if typeAccounts.isEmpty {
                            Text("No \(type.displayName) accounts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(typeAccounts) { account in
                                AccountRow(account: account, theme: theme)
                                    .contentShape(Rectangle())
                                    .onTapGesture { edit(account) }
                            }
                            .onDelete { indexSet in
                                deleteAccounts(typeAccounts: typeAccounts, at: indexSet)
                            }
                        }
                    } header: {
                        Text(type.displayName)
                            .font(.headline)
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chatBackground)
        }
        .sheet(isPresented: $showEditor) {
            AccountEditorSheet(
                viewModel: viewModel,
                account: editingAccount ?? .blank,
                isPresented: $showEditor)
        }
    }

    private var header: some View {
        HStack {
            Text("Chart of Accounts")
                .font(.headline)
            Spacer()
            Button {
                editingAccount = .blank
                showEditor = true
            } label: {
                Label("New Account", systemImage: "plus")
            }
        }
        .padding()
        .background(theme.secondaryBackground)
    }

    private func edit(_ account: BooksAccount) {
        editingAccount = account
        showEditor = true
    }

    private func deleteAccounts(typeAccounts: [BooksAccount], at offsets: IndexSet) {
        for offset in offsets {
            let account = typeAccounts[offset]
            if let id = account.id {
                Task { await viewModel.deleteAccount(id: id) }
            }
        }
    }
}

private struct AccountRow: View {
    let account: BooksAccount
    let theme: ThemeStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.code)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundStyle(theme.accent)
                    Text(account.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.chatText)
                }
                if let description = account.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if account.isBank {
                Label("Bank", systemImage: "building.columns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(account.balance, format: .currency(code: "AUD"))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(theme.chatText)
                Text(account.taxLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Account editor

private struct AccountEditorSheet: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var account: BooksAccount
    private let isNew: Bool

    init(viewModel: BooksViewModel, account: BooksAccount, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._account = State(initialValue: account)
        self.isNew = account.id == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Account" : "Edit Account")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.code.isEmpty || account.name.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)

            Form {
                TextField("Code", text: $account.code)
                TextField("Name", text: $account.name)
                Picker("Type", selection: $account.type) {
                    ForEach(BooksAccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                TextField("Tax type", text: $account.taxType)
                TextField("Tax label", text: $account.taxLabel)
                Toggle("Bank account", isOn: $account.isBank)
                if account.isBank {
                    TextField("Account number", text: binding(for: $account.bankAccountNumber))
                }
                TextField("Opening balance", value: $account.openingBalance, format: .number)
                TextField("Description", text: binding(for: $account.description))
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 460)

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
            var mutable = account
            await viewModel.saveAccount(&mutable)
            isPresented = false
        }
    }
}
