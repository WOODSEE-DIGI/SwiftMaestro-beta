import Foundation

// MARK: - Accountant Export Service

/// Produces accountant-ready reports from MaestroBooks. All outputs are
/// CSV-based so they open in Excel / Google Sheets and can be emailed to
/// accountants without specialised software.
enum AccountantExportService {

    struct ReportSet {
        let trialBalance: String
        let profitAndLoss: String
        let balanceSheet: String
        let generalLedger: String
        let arAging: String
        let apAging: String
    }

    /// Generates the full accountant pack from the current Books database.
    static func generateAll(
        database: BooksDatabase = .shared,
        seller: BooksSeller = .load()
    ) throws -> ReportSet {
        let accounts = try database.accounts()
        let invoices = try database.invoices()
        let clients = try database.clients()
        let bills = try database.bills()
        let suppliers = try database.suppliers()
        let journalEntries = try database.journalEntries()
        let payments = try invoices.flatMap { try database.payments(invoiceID: $0.id ?? 0) }

        return ReportSet(
            trialBalance: trialBalanceCSV(accounts: accounts),
            profitAndLoss: profitAndLossCSV(
                accounts: accounts, invoices: invoices, bills: bills, seller: seller),
            balanceSheet: balanceSheetCSV(
                accounts: accounts, invoices: invoices, bills: bills),
            generalLedger: generalLedgerCSV(
                accounts: accounts, invoices: invoices, bills: bills,
                journalEntries: journalEntries, database: database),
            arAging: arAgingCSV(invoices: invoices, clients: clients, payments: payments),
            apAging: apAgingCSV(bills: bills, suppliers: suppliers))
    }

    // MARK: - Trial Balance

    private static func trialBalanceCSV(accounts: [BooksAccount]) -> String {
        var lines = ["Code,Name,Type,Debit,Credit"]
        for account in accounts.sorted(by: { $0.code < $1.code }) {
            let balance = account.balance + account.openingBalance
            let debit = balance > 0 ? balance : 0
            let credit = balance < 0 ? -balance : 0
            lines.append(csvRow([
                account.code, account.name, account.type.rawValue,
                format(debit), format(credit)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Profit & Loss

    private static func profitAndLossCSV(
        accounts: [BooksAccount],
        invoices: [BooksInvoice],
        bills: [BooksBill],
        seller: BooksSeller
    ) -> String {
        let incomeAccounts = accounts.filter { $0.type == .income }
        let expenseAccounts = accounts.filter { $0.type == .expense }

        let incomeTotal = invoices.reduce(0) { $0 + $1.subtotal(invoices: invoices, database: BooksDatabase.shared) }
        let expenseTotal = bills.reduce(0) { $0 + $1.subtotal(database: BooksDatabase.shared) }
        let net = incomeTotal - expenseTotal

        var lines: [String] = []
        lines.append("Profit & Loss")
        lines.append("Currency,\(seller.currency)")
        lines.append("")
        lines.append("Income,,Amount")
        for account in incomeAccounts {
            let amount = invoices
                .filter { $0.accountCode == account.code }
                .reduce(0) { $0 + $1.subtotal(invoices: invoices, database: BooksDatabase.shared) }
            lines.append(csvRow([account.code, account.name, format(amount)]))
        }
        lines.append(csvRow(["", "Total Income", format(incomeTotal)]))
        lines.append("")
        lines.append("Expenses,,Amount")
        for account in expenseAccounts {
            let amount = bills
                .filter { $0.lineItems(database: BooksDatabase.shared).contains(where: { $0.accountCode == account.code }) }
                .reduce(0) { $0 + $1.subtotal(forAccountCode: account.code, database: BooksDatabase.shared) }
            lines.append(csvRow([account.code, account.name, format(amount)]))
        }
        lines.append(csvRow(["", "Total Expenses", format(expenseTotal)]))
        lines.append("")
        lines.append(csvRow(["", "Net Profit/(Loss)", format(net)]))
        return lines.joined(separator: "\n")
    }

    // MARK: - Balance Sheet

    private static func balanceSheetCSV(
        accounts: [BooksAccount],
        invoices: [BooksInvoice],
        bills: [BooksBill]
    ) -> String {
        let assets = accounts.filter { $0.type == .asset }
        let liabilities = accounts.filter { $0.type == .liability }
        let equity = accounts.filter { $0.type == .equity }

        let arTotal = invoices
            .filter { $0.status == .authorised || $0.status == .draft }
            .reduce(0) { $0 + $1.total(invoices: invoices, database: BooksDatabase.shared) }
        let apTotal = bills
            .filter { $0.status == .awaitingPayment || $0.status == .draft }
            .reduce(0) { $0 + $1.total(database: BooksDatabase.shared) }

        var lines: [String] = []
        lines.append("Balance Sheet")
        lines.append("Assets,,Amount")
        for account in assets {
            let balance = account.balance + account.openingBalance
            lines.append(csvRow([account.code, account.name, format(balance)]))
        }
        lines.append(csvRow(["120", "Accounts Receivable", format(arTotal)]))
        let totalAssets = assets.reduce(0) { $0 + $1.balance + $1.openingBalance } + arTotal
        lines.append(csvRow(["", "Total Assets", format(totalAssets)]))
        lines.append("")
        lines.append("Liabilities,,Amount")
        for account in liabilities {
            let balance = account.balance + account.openingBalance
            lines.append(csvRow([account.code, account.name, format(balance)]))
        }
        lines.append(csvRow(["820", "Accounts Payable", format(apTotal)]))
        let totalLiabilities = liabilities.reduce(0) { $0 + $1.balance + $1.openingBalance } + apTotal
        lines.append(csvRow(["", "Total Liabilities", format(totalLiabilities)]))
        lines.append("")
        lines.append("Equity,,Amount")
        for account in equity {
            let balance = account.balance + account.openingBalance
            lines.append(csvRow([account.code, account.name, format(balance)]))
        }
        let totalEquity = equity.reduce(0) { $0 + $1.balance + $1.openingBalance }
        lines.append(csvRow(["", "Total Equity", format(totalEquity)]))
        lines.append("")
        lines.append(csvRow(["", "Liabilities + Equity", format(totalLiabilities + totalEquity)]))
        return lines.joined(separator: "\n")
    }

    // MARK: - General Ledger

    private static func generalLedgerCSV(
        accounts: [BooksAccount],
        invoices: [BooksInvoice],
        bills: [BooksBill],
        journalEntries: [BooksJournalEntry],
        database: BooksDatabase
    ) -> String {
        var lines = ["Date,Reference,Account,AccountName,Description,Debit,Credit,Balance"]
        for account in accounts.sorted(by: { $0.code < $1.code }) {
            var running = account.openingBalance
            // Invoices (Sales / A/R)
            for invoice in invoices {
                let total = invoice.total(invoices: invoices, database: database)
                if invoice.accountCode == account.code {
                    running += total
                    lines.append(csvRow([
                        iso(invoice.issueDate), invoice.number, account.code, account.name,
                        "Invoice \(invoice.number)", "0.00", format(total), format(running)
                    ]))
                }
            }
            // Bills
            for bill in bills {
                for item in bill.lineItems(database: database) where item.accountCode == account.code {
                    running += item.amount
                    lines.append(csvRow([
                        iso(bill.issueDate), bill.number, account.code, account.name,
                        item.description, format(item.amount), "0.00", format(running)
                    ]))
                }
            }
            // Journal entries
            for entry in journalEntries {
                for line in (try? database.journalLines(entryID: entry.id ?? 0)) ?? [] where line.accountCode == account.code {
                    running += line.debit - line.credit
                    lines.append(csvRow([
                        iso(entry.date), entry.reference ?? "", account.code, account.name,
                        line.description ?? entry.memo, format(line.debit), format(line.credit), format(running)
                    ]))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - A/R Aging

    private static func arAgingCSV(
        invoices: [BooksInvoice],
        clients: [BooksClient],
        payments: [BooksPayment]
    ) -> String {
        let now = Date()
        var lines = ["Client,Invoice,DueDate,Current,1-30,31-60,61-90,90+,TotalOutstanding"]
        for invoice in invoices where invoice.status != .paid && invoice.status != .voided {
            guard let client = clients.first(where: { $0.id == invoice.clientID }) else { continue }
            let total = invoice.total(invoices: invoices, database: .shared)
            let paid = payments.filter { $0.invoiceID == invoice.id }.reduce(0) { $0 + $1.amount }
            let outstanding = max(total - paid, 0)
            guard outstanding > 0.005 else { continue }
            let due = invoice.dueDate ?? invoice.issueDate
            let days = Calendar.current.dateComponents([.day], from: due, to: now).day ?? 0
            let buckets = agingBuckets(days: days, amount: outstanding)
            lines.append(csvRow([
                client.name, invoice.number, iso(due),
                format(buckets.current), format(buckets.d30), format(buckets.d60),
                format(buckets.d90), format(buckets.over90), format(outstanding)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - A/P Aging

    private static func apAgingCSV(
        bills: [BooksBill],
        suppliers: [BooksSupplier]
    ) -> String {
        let now = Date()
        var lines = ["Supplier,Bill,DueDate,Current,1-30,31-60,61-90,90+,TotalOutstanding"]
        for bill in bills where bill.status != .paid && bill.status != .voided {
            guard let supplier = suppliers.first(where: { $0.id == bill.supplierID }) else { continue }
            let total = bill.total(database: .shared)
            let due = bill.dueDate ?? bill.issueDate
            let days = Calendar.current.dateComponents([.day], from: due, to: now).day ?? 0
            let buckets = agingBuckets(days: days, amount: total)
            lines.append(csvRow([
                supplier.name, bill.number, iso(due),
                format(buckets.current), format(buckets.d30), format(buckets.d60),
                format(buckets.d90), format(buckets.over90), format(total)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func agingBuckets(days: Int, amount: Double) -> (current: Double, d30: Double, d60: Double, d90: Double, over90: Double) {
        switch days {
        case ..<0: return (amount, 0, 0, 0, 0)
        case 0...30: return (amount, 0, 0, 0, 0)
        case 31...60: return (0, amount, 0, 0, 0)
        case 61...90: return (0, 0, amount, 0, 0)
        case 91...: return (0, 0, 0, amount, 0)
        default: return (0, 0, 0, 0, amount)
        }
    }

    private static func csvRow(_ values: [String]) -> String {
        values.map { field in
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            if field.contains(",") || field.contains("\n") || field.contains("\"") {
                return "\"\(escaped)\""
            }
            return escaped
        }.joined(separator: ",")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - BooksInvoice helpers for reporting

extension BooksInvoice {
    func lineItems(database: BooksDatabase) -> [BooksLineItem] {
        (try? database.lineItems(invoiceID: id ?? 0)) ?? []
    }

    func subtotal(invoices: [BooksInvoice], database: BooksDatabase) -> Double {
        lineItems(database: database).reduce(0) { $0 + $1.amount }
    }

    func total(invoices: [BooksInvoice], database: BooksDatabase) -> Double {
        subtotal(invoices: invoices, database: database) * (1 + taxRate)
    }
}

extension BooksBill {
    func lineItems(database: BooksDatabase) -> [BooksBillLineItem] {
        (try? database.billLineItems(billID: id ?? 0)) ?? []
    }

    func subtotal(database: BooksDatabase) -> Double {
        lineItems(database: database).reduce(0) { $0 + $1.amount }
    }

    func subtotal(forAccountCode code: String, database: BooksDatabase) -> Double {
        lineItems(database: database)
            .filter { $0.accountCode == code }
            .reduce(0) { $0 + $1.amount }
    }

    func total(database: BooksDatabase) -> Double {
        subtotal(database: database) * (1 + taxRate)
    }
}
