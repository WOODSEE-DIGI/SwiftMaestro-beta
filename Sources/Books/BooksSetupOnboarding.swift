import SwiftUI

// MARK: - Books Setup Onboarding

/// First-run screen for MaestroBooks. All setup is shown on a single scrollable
/// page: welcome, region/language, data checklist and default Chart of Accounts.
struct BooksSetupOnboarding: View {
    @Environment(ThemeStore.self) private var theme
    @State private var language = LocaleSettings.shared.language
    @State private var country = LocaleSettings.shared.country

    private let countries = [
        "AU", "US", "GB", "CA", "NZ", "IE", "DE", "FR", "ES", "IT",
        "NL", "BE", "AT", "PT", "BR", "JP", "SG", "IN"
    ]

    /// Called when the user taps "Open MaestroBooks". The caller is responsible
    /// for persisting settings and swapping to the main UI.
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    welcomeSection
                    regionSection
                    dataNeedsSection
                    coaSection
                }
                .padding(28)
            }
            Divider()
            HStack {
                Spacer()
                Button("Open MaestroBooks") { finish() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480)
        .background(theme.chatBackground)
    }

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to MaestroBooks")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(theme.chatText)
            Text("A simple, private bookkeeping system that lives on your Mac. Choose your region below, review the default accounts, then open the app.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where do you do business?")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.chatText)
            Text("This sets your default tax labels, currency, and the business identifier we'll collect from clients and suppliers (e.g., ABN, EIN, VAT).")
                .font(.body)
                .foregroundStyle(.secondary)

            Form {
                Picker("Language", selection: $language) {
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Português").tag("pt")
                    Text("日本語").tag("ja")
                    Text("中文").tag("zh")
                }
                Picker("Country / Region", selection: $country) {
                    ForEach(countries, id: \.self) { code in
                        Text(localeName(for: code)).tag(code)
                    }
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                Text("Business identifier: \(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel) • Currency: \(LocaleSettings.shared.defaultCurrency) • Tax label: \(LocaleSettings.shared.salesTaxLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dataNeedsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What you'll need")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.chatText)
            Text("MaestroBooks can start empty, but you'll get the most from it if you gather these details:")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                CheckItem(icon: "person.2", title: "Clients & suppliers", detail: "Name, email, address, and \(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel) if you have it.")
                CheckItem(icon: "list.bullet.rectangle", title: "Chart of Accounts", detail: "We'll create a default set based on your country. You can edit it anytime.")
                CheckItem(icon: "doc.text", title: "Opening balances", detail: "Bank balances, unpaid invoices, and any amounts owed to suppliers.")
                CheckItem(icon: "arrow.down.doc", title: "Imports", detail: "CSV or IIF exports from Xero, QuickBooks, or spreadsheets.")
            }
        }
    }

    private var coaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default Chart of Accounts")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.chatText)
            Text("These accounts are ready to use. You can add, rename, or remove accounts once you're inside MaestroBooks.")
                .font(.body)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(defaultAccounts, id: \.code) { account in
                        HStack {
                            Text(account.code)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Text(account.name)
                                .font(.body)
                            Spacer()
                            Text(account.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var defaultAccounts: [(code: String, name: String, type: String)] {
        switch country {
        case "US":
            return [
                ("1200", "Accounts Receivable", "Asset"),
                ("2000", "Sales Revenue", "Income"),
                ("5000", "Cost of Goods Sold", "Expense"),
                ("6000", "Office Expenses", "Expense"),
                ("1010", "Checking Account", "Asset"),
                ("3010", "Owner Equity", "Equity")
            ]
        case "GB":
            return [
                ("1100", "Debtors", "Asset"),
                ("4000", "Sales", "Income"),
                ("5000", "Cost of Sales", "Expense"),
                ("7000", "Overheads", "Expense"),
                ("1200", "Bank Current Account", "Asset"),
                ("3000", "Capital", "Equity")
            ]
        default:
            return [
                ("120", "Accounts Receivable", "Asset"),
                ("200", "Sales", "Income"),
                ("429", "General Expenses", "Expense"),
                ("500", "Cost of Goods Sold", "Expense"),
                ("610", "Office Supplies", "Expense"),
                ("800", "Bank Account", "Asset"),
                ("820", "Credit Card", "Liability"),
                ("900", "Owner Equity", "Equity")
            ]
        }
    }

    private func localeName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func finish() {
        LocaleSettings.shared.language = language
        LocaleSettings.shared.country = country
        LocaleSettings.shared.hasCompletedLocaleSetup = true
        LocaleSettings.shared.hasCompletedBooksSetup = true
        onComplete()
    }
}

private struct CheckItem: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
