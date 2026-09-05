import Foundation

// MARK: - Books Import Service

/// Imports accounting data from QuickBooks / Xero export files into
/// MaestroBooks. No live API connection — this is for migrations.
@MainActor
enum BooksImportService {

    enum ImportSource: String, CaseIterable, Sendable {
        case xeroContacts = "Xero Contacts CSV"
        case xeroChartOfAccounts = "Xero Chart of Accounts CSV"
        case quickBooksCustomers = "QuickBooks Customer List CSV"
        case quickBooksVendors = "QuickBooks Vendor List CSV"
        case quickBooksChartOfAccounts = "QuickBooks Chart of Accounts CSV"
        case quickBooksIIF = "QuickBooks IIF"
    }

    struct ImportResult: Sendable {
        let imported: Int
        let skipped: Int
        let errors: [String]
        let flagged: [RiskFlagMatch]
    }

    struct RiskFlagMatch: Sendable {
        let name: String
        let taxID: String?
        let flag: RiskFlag
    }

    // MARK: - Public entry

    static func importFile(
        at url: URL,
        source: ImportSource,
        database: BooksDatabase = .shared
    ) async throws -> ImportResult {
        let data = try String(contentsOf: url, encoding: .utf8)
        switch source {
        case .xeroContacts:
            return try importContactsCSV(data, database: database)
        case .xeroChartOfAccounts:
            return try importChartOfAccountsCSV(data, database: database)
        case .quickBooksCustomers, .quickBooksVendors:
            return try importQuickBooksContactsCSV(data, source: source, database: database)
        case .quickBooksChartOfAccounts:
            return try importQuickBooksChartOfAccountsCSV(data, database: database)
        case .quickBooksIIF:
            return try importQuickBooksIIF(data, database: database)
        }
    }

    // MARK: - Xero Contacts

    private static func importContactsCSV(
        _ csv: String,
        database: BooksDatabase
    ) throws -> ImportResult {
        let rows = parseCSV(csv)
        guard let headers = rows.first else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Empty CSV"], flagged: [])
        }
        let nameIdx = headers.firstIndex(of: "Name")
        let emailIdx = headers.firstIndex(of: "EmailAddress")
        let phoneIdx = headers.firstIndex(of: "PhoneNumber")
        let taxIdx = headers.firstIndex(of: "TaxNumber")
        let addressIdx = headers.firstIndex(of: "POAddressLine1")
        let cityIdx = headers.firstIndex(of: "POCity")
        let regionIdx = headers.firstIndex(of: "PORegion")
        let postIdx = headers.firstIndex(of: "POPostalCode")
        let countryIdx = headers.firstIndex(of: "POCountry")

        guard let nameIdx else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Missing 'Name' column"], flagged: [])
        }

        var imported = 0
        var skipped = 0
        var errors: [String] = []
        var flagged: [RiskFlagMatch] = []

        for row in rows.dropFirst() {
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { skipped += 1; continue }
            let taxID = value(at: taxIdx, in: row)
            let country = value(at: countryIdx, in: row) ?? "AU"

            if let flag = RiskFlagService.shared.flag(for: name, taxID: taxID, country: country) {
                flagged.append(RiskFlagMatch(name: name, taxID: taxID, flag: flag))
            }

            var client = BooksClient.blank
            client.name = name
            client.email = value(at: emailIdx, in: row)
            client.phone = value(at: phoneIdx, in: row)
            client.taxNumber = taxID
            client.poAddressLine1 = value(at: addressIdx, in: row)
            client.poCity = value(at: cityIdx, in: row)
            client.poRegion = value(at: regionIdx, in: row)
            client.poPostalCode = value(at: postIdx, in: row)
            client.poCountry = country

            do {
                if try database.client(named: name) == nil {
                    _ = try database.saveClient(&client)
                    imported += 1
                } else {
                    skipped += 1
                }
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors, flagged: flagged)
    }

    // MARK: - Xero Chart of Accounts

    private static func importChartOfAccountsCSV(
        _ csv: String,
        database: BooksDatabase
    ) throws -> ImportResult {
        let rows = parseCSV(csv)
        guard let headers = rows.first else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Empty CSV"], flagged: [])
        }
        let codeIdx = headers.firstIndex(of: "Code")
        let nameIdx = headers.firstIndex(of: "Name")
        let typeIdx = headers.firstIndex(of: "Type")

        guard let codeIdx, let nameIdx else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Missing Code or Name column"], flagged: [])
        }

        var imported = 0
        var skipped = 0
        var errors: [String] = []

        for row in rows.dropFirst() {
            let code = row[codeIdx].trimmingCharacters(in: .whitespaces)
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !name.isEmpty else { skipped += 1; continue }

            var account = BooksAccount.blank
            account.code = code
            account.name = name
            account.type = mapXeroAccountType(value(at: typeIdx, in: row) ?? "")
            account.taxType = "NONE"
            account.taxLabel = "None"

            do {
                if try database.account(code: code) == nil {
                    _ = try database.saveAccount(&account)
                    imported += 1
                } else {
                    skipped += 1
                }
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors, flagged: [])
    }

    // MARK: - QuickBooks CSV contacts

    private static func importQuickBooksContactsCSV(
        _ csv: String,
        source: ImportSource,
        database: BooksDatabase
    ) throws -> ImportResult {
        let rows = parseCSV(csv)
        guard let headers = rows.first else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Empty CSV"], flagged: [])
        }

        // QuickBooks customer/vendor export columns vary; support common labels.
        let nameIdx = firstIndex(in: headers, matching: ["Name", "Customer", "Vendor", "Company Name"])
        let emailIdx = firstIndex(in: headers, matching: ["Email", "E-mail", "Email Address"])
        let phoneIdx = firstIndex(in: headers, matching: ["Phone", "Phone Number", "Main Phone"])
        let taxIdx = firstIndex(in: headers, matching: ["Tax Number", "ABN", "VAT Number", "EIN"])

        guard let nameIdx else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Missing name column"], flagged: [])
        }

        var imported = 0
        var skipped = 0
        var errors: [String] = []
        var flagged: [RiskFlagMatch] = []
        let isVendor = source == .quickBooksVendors

        for row in rows.dropFirst() {
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { skipped += 1; continue }
            let taxID = value(at: taxIdx, in: row)

            if let flag = RiskFlagService.shared.flag(for: name, taxID: taxID) {
                flagged.append(RiskFlagMatch(name: name, taxID: taxID, flag: flag))
            }

            if isVendor {
                var supplier = BooksSupplier.blank
                supplier.name = name
                supplier.email = value(at: emailIdx, in: row)
                supplier.phone = value(at: phoneIdx, in: row)
                supplier.taxNumber = taxID
                do {
                    if try database.supplier(named: name) == nil {
                        _ = try database.saveSupplier(&supplier)
                        imported += 1
                    } else {
                        skipped += 1
                    }
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }
            } else {
                var client = BooksClient.blank
                client.name = name
                client.email = value(at: emailIdx, in: row)
                client.phone = value(at: phoneIdx, in: row)
                client.taxNumber = taxID
                do {
                    if try database.client(named: name) == nil {
                        _ = try database.saveClient(&client)
                        imported += 1
                    } else {
                        skipped += 1
                    }
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors, flagged: flagged)
    }

    // MARK: - QuickBooks Chart of Accounts

    private static func importQuickBooksChartOfAccountsCSV(
        _ csv: String,
        database: BooksDatabase
    ) throws -> ImportResult {
        let rows = parseCSV(csv)
        guard let headers = rows.first else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Empty CSV"], flagged: [])
        }
        let codeIdx = firstIndex(in: headers, matching: ["Accno", "Account Number", "Number"])
        let nameIdx = firstIndex(in: headers, matching: ["Account", "Account Name", "Name"])
        let typeIdx = firstIndex(in: headers, matching: ["Type", "Account Type"])

        guard let codeIdx, let nameIdx else {
            return ImportResult(imported: 0, skipped: 0, errors: ["Missing account number or name"], flagged: [])
        }

        var imported = 0
        var skipped = 0
        var errors: [String] = []

        for row in rows.dropFirst() {
            let code = row[codeIdx].trimmingCharacters(in: .whitespaces)
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !name.isEmpty else { skipped += 1; continue }

            var account = BooksAccount.blank
            account.code = code
            account.name = name
            account.type = mapQuickBooksAccountType(value(at: typeIdx, in: row) ?? "")
            account.taxType = "NONE"
            account.taxLabel = "None"

            do {
                if try database.account(code: code) == nil {
                    _ = try database.saveAccount(&account)
                    imported += 1
                } else {
                    skipped += 1
                }
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors, flagged: [])
    }

    // MARK: - QuickBooks IIF (basic contact + COA support)

    private static func importQuickBooksIIF(
        _ iif: String,
        database: BooksDatabase
    ) throws -> ImportResult {
        var imported = 0
        var skipped = 0
        var errors: [String] = []
        var flagged: [RiskFlagMatch] = []

        let sections = iif.components(separatedBy: "!\n")
        for section in sections {
            if section.hasPrefix("CUST") || section.hasPrefix("VEND") {
                let isVendor = section.hasPrefix("VEND")
                let rows = parseCSV(section, delimiter: "\t")
                guard rows.count > 1 else { continue }
                let headers = rows[0]
                let nameIdx = headers.firstIndex(of: "NAME")
                guard let nameIdx else { continue }
                for row in rows.dropFirst() {
                    let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { continue }
                    if let flag = RiskFlagService.shared.flag(for: name, taxID: nil) {
                        flagged.append(RiskFlagMatch(name: name, taxID: nil, flag: flag))
                    }
                    if isVendor {
                        var supplier = BooksSupplier.blank
                        supplier.name = name
                        do {
                            if try database.supplier(named: name) == nil {
                                _ = try database.saveSupplier(&supplier)
                                imported += 1
                            } else {
                                skipped += 1
                            }
                        } catch {
                            errors.append("\(name): \(error.localizedDescription)")
                        }
                    } else {
                        var client = BooksClient.blank
                        client.name = name
                        do {
                            if try database.client(named: name) == nil {
                                _ = try database.saveClient(&client)
                                imported += 1
                            } else {
                                skipped += 1
                            }
                        } catch {
                            errors.append("\(name): \(error.localizedDescription)")
                        }
                    }
                }
            } else if section.hasPrefix("ACCNT") {
                let rows = parseCSV(section, delimiter: "\t")
                guard rows.count > 1 else { continue }
                let headers = rows[0]
                let nameIdx = headers.firstIndex(of: "NAME")
                let typeIdx = headers.firstIndex(of: "ACCNTTYPE")
                guard let nameIdx else { continue }
                for row in rows.dropFirst() {
                    let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { continue }
                    var account = BooksAccount.blank
                    account.code = String(name.prefix(20))
                    account.name = name
                    account.type = mapQuickBooksAccountType(value(at: typeIdx, in: row) ?? "")
                    account.taxType = "NONE"
                    account.taxLabel = "None"
                    do {
                        if try database.account(code: account.code) == nil {
                            _ = try database.saveAccount(&account)
                            imported += 1
                        } else {
                            skipped += 1
                        }
                    } catch {
                        errors.append("\(name): \(error.localizedDescription)")
                    }
                }
            }
        }
        return ImportResult(imported: imported, skipped: skipped, errors: errors, flagged: flagged)
    }

    // MARK: - CSV parser

    private static func parseCSV(_ csv: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        for char in csv {
            if char == "\"" {
                if insideQuotes, let next = csv.dropFirst(csv.distance(from: csv.startIndex, to: csv.firstIndex(of: char) ?? csv.startIndex)).first, next == "\"" {
                    currentField.append("\"")
                } else {
                    insideQuotes.toggle()
                }
            } else if char == delimiter, !insideQuotes {
                currentRow.append(currentField)
                currentField = ""
            } else if char == "\n", !insideQuotes {
                currentRow.append(currentField)
                if !currentRow.isEmpty, currentRow != [""] {
                    rows.append(currentRow)
                }
                currentRow = []
                currentField = ""
            } else {
                currentField.append(char)
            }
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }
        return rows
    }

    // MARK: - Helpers

    private static func value(at index: Int?, in row: [String]) -> String? {
        guard let index, index < row.count else { return nil }
        let trimmed = row[index].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstIndex(in headers: [String], matching candidates: [String]) -> Int? {
        for candidate in candidates {
            if let idx = headers.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(candidate) == .orderedSame }) {
                return idx
            }
        }
        return nil
    }

    private static func mapXeroAccountType(_ raw: String) -> BooksAccountType {
        switch raw.lowercased() {
        case "asset", "bank", "current asset", "fixed asset": return .asset
        case "liability", "current liability", "non-current liability": return .liability
        case "equity": return .equity
        case "revenue", "income", "sales", "other income": return .income
        case "expense", "cost of goods sold", "overhead": return .expense
        default: return .expense
        }
    }

    private static func mapQuickBooksAccountType(_ raw: String) -> BooksAccountType {
        switch raw.lowercased() {
        case "accounts receivable", "bank", "fixed asset", "other asset", "other current asset": return .asset
        case "accounts payable", "credit card", "long term liability", "other current liability": return .liability
        case "equity": return .equity
        case "income", "other income": return .income
        case "expense", "cost of goods sold", "other expense": return .expense
        default: return .expense
        }
    }
}
