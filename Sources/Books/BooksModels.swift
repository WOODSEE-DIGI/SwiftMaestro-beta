import Foundation
import GRDB

// MARK: - MaestroBooks Models
//
// Invoicing domain models. Xero-compatible by design: statuses are Xero's
// own strings, line items carry Xero account codes + tax types, contacts
// use the Xero PO-address shape, and `xero_id` columns are reserved for
// API sync (Phase 2, OAuth2 via SecretsStore).

/// Xero invoice statuses — stored verbatim (1:1, no mapping table).
enum BooksInvoiceStatus: String, Codable, CaseIterable, Sendable {
    case draft = "DRAFT"
    case authorised = "AUTHORISED"   // = "sent/issued" in Xero
    case paid = "PAID"
    case voided = "VOIDED"

    var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .authorised: return "Sent"
        case .paid: return "Paid"
        case .voided: return "Voided"
        }
    }

    /// Xero CSV "Sent" column value.
    var xeroSent: String { self == .draft ? "FALSE" : "TRUE" }
}

struct BooksClient: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var email: String?
    var phone: String?
    var poAddressLine1: String?
    var poAddressLine2: String?
    var poCity: String?
    var poRegion: String?
    var poPostalCode: String?
    var poCountry: String?
    /// ABN — maps to Xero's contact TaxNumber.
    var taxNumber: String?
    var notes: String?
    /// Reserved for Xero API sync.
    var xeroID: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "clients"

    /// GRDB maps CodingKeys raw values to database columns 1:1 — every
    /// camelCase property needs its snake_case column name here or inserts
    /// AND queries fail with "no such column" (learned the hard way).
    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, notes
        case poAddressLine1 = "po_address_line1"
        case poAddressLine2 = "po_address_line2"
        case poCity = "po_city"
        case poRegion = "po_region"
        case poPostalCode = "po_postal_code"
        case poCountry = "po_country"
        case taxNumber = "tax_number"
        case xeroID = "xero_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let name = Column(CodingKeys.name)
    }

    /// Empty form value for "New Client" editors.
    static var blank: BooksClient {
        BooksClient(
            id: nil, name: "", email: nil, phone: nil,
            poAddressLine1: nil, poAddressLine2: nil, poCity: nil, poRegion: nil,
            poPostalCode: nil, poCountry: nil, taxNumber: nil, notes: nil,
            xeroID: nil, createdAt: Date(), updatedAt: Date())
    }

    /// Single-line address for display/PDF.
    var addressBlock: String {
        [poAddressLine1, poAddressLine2, poCity, poRegion, poPostalCode, poCountry]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct BooksInvoice: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var number: String
    var clientID: Int64
    var issueDate: Date
    var dueDate: Date?
    var statusRaw: String
    var currency: String
    /// Tax rate snapshot at creation (0.10 = AU GST). Invoices never follow
    /// later business-settings changes — accounting records stay immutable.
    var taxRate: Double
    /// Tax display name snapshot ("GST" / "VAT" / "Sales Tax").
    var taxLabel: String
    /// Xero tax type (OUTPUT = GST on income).
    var taxType: String
    /// Xero default account code for lines (200 = Sales).
    var accountCode: String
    var notes: String?
    var pdfPath: String?
    var xeroID: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "invoices"

    enum CodingKeys: String, CodingKey {
        case id, number, currency, notes
        case clientID = "client_id"
        case issueDate = "issue_date"
        case dueDate = "due_date"
        case statusRaw = "status"
        case taxRate = "tax_rate"
        case taxLabel = "tax_label"
        case taxType = "tax_type"
        case accountCode = "account_code"
        case pdfPath = "pdf_path"
        case xeroID = "xero_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let statusRaw = Column(CodingKeys.statusRaw)
        static let issueDate = Column(CodingKeys.issueDate)
        static let clientID = Column(CodingKeys.clientID)
    }

    var status: BooksInvoiceStatus {
        get { BooksInvoiceStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    /// Rate as a display percentage without trailing zeros ("10", "8.1").
    var taxRatePercentString: String {
        String(format: "%g", taxRate * 100)
    }
}

struct BooksLineItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var invoiceID: Int64
    var position: Int
    var description: String
    var quantity: Double
    var unitAmount: Double
    /// Line discount as a percentage (0–100). Matches Xero's Discount column.
    var discount: Double = 0
    /// Per-line Xero override; nil = invoice default.
    var accountCode: String?
    var taxType: String?

    static let databaseTableName = "line_items"

    enum CodingKeys: String, CodingKey {
        case id, position, description, quantity, discount
        case invoiceID = "invoice_id"
        case unitAmount = "unit_amount"
        case accountCode = "account_code"
        case taxType = "tax_type"
    }

    var amount: Double { quantity * unitAmount * (1 - discount / 100) }
}

/// Business expense (a supplier bill). Maps to a Xero ACCPAY invoice:
/// supplier becomes a Xero contact, INPUT tax type, expense account code.
/// Statuses reuse the Xero-verbatim invoice status enum.
struct BooksExpense: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var supplier: String
    var expenseDescription: String
    /// Supplier's own invoice/reference number.
    var reference: String?
    /// Xero expense account code (429 = General expenses).
    var accountCode: String
    var issueDate: Date
    var statusRaw: String
    var currency: String
    /// Tax rate snapshot (0.10 = AU GST on expenses).
    var taxRate: Double
    /// Xero INPUT tax type (INPUT / INPUT2 / EXEMPTINPUT per country).
    var taxType: String
    /// Pre-tax amount; tax + total are derived.
    var subtotal: Double
    var notes: String?
    /// Reserved for Xero API sync.
    var xeroID: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "expenses"

    enum CodingKeys: String, CodingKey {
        case id, supplier, reference, currency, notes
        case expenseDescription = "description"
        case accountCode = "account_code"
        case issueDate = "issue_date"
        case statusRaw = "status"
        case taxRate = "tax_rate"
        case taxType = "tax_type"
        case subtotal
        case xeroID = "xero_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let statusRaw = Column(CodingKeys.statusRaw)
        static let issueDate = Column(CodingKeys.issueDate)
    }

    var status: BooksInvoiceStatus {
        get { BooksInvoiceStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var tax: Double { subtotal * taxRate }
    var total: Double { subtotal + tax }
}

struct BooksPayment: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var invoiceID: Int64
    var date: Date
    var amount: Double
    var method: String?
    var note: String?
    var createdAt: Date

    static let databaseTableName = "payments"

    enum CodingKeys: String, CodingKey {
        case id, date, amount, method, note
        case invoiceID = "invoice_id"
        case createdAt = "created_at"
    }
}

/// Seller/business profile (the "from" on invoices). UserDefaults-backed —
/// edited in the MaestroBooks Business section.
struct BooksSeller: Codable, Sendable {
    var name = ""
    var abn = ""
    var address = ""
    var email = ""
    var phone = ""
    /// Payment instructions shown in the invoice footer (BSB/account etc.).
    var paymentDetails = ""
    /// Default Xero account code for new invoices (200 = Sales).
    var defaultAccountCode = "200"
    /// Default Xero expense account code (429 = General expenses).
    var defaultExpenseAccountCode = "429"
    /// Xero INPUT tax type for expenses (country-dependent like taxType).
    var expenseTaxType = "INPUT"

    // MARK: Locale & tax (international support)
    /// ISO 4217 operating currency. Choosing it drives sensible tax defaults.
    var currency = "AUD"
    /// Display name of the sales tax (GST / VAT / Sales Tax / none).
    var taxLabel = "GST"
    /// Tax rate as a fraction (0.10 = 10%). 0 = tax-free operation.
    var taxRate = 0.10
    /// Xero tax type code for income lines (org-dependent).
    var taxType = "OUTPUT"
    /// Label for the business tax number on letterheads (ABN / VAT No / EIN).
    var taxRegistrationLabel = "ABN"
    /// Invoice title override; empty = derive ("TAX INVOICE" for GST,
    /// "VAT INVOICE" for VAT, "INVOICE" when tax-free).
    var invoiceTitle = ""

    /// Backward-compatible decode: profiles saved before the locale fields
    /// existed must keep their data (decodeIfPresent + AU-era defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        abn = try c.decodeIfPresent(String.self, forKey: .abn) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        paymentDetails = try c.decodeIfPresent(String.self, forKey: .paymentDetails) ?? ""
        defaultAccountCode = try c.decodeIfPresent(String.self, forKey: .defaultAccountCode) ?? "200"
        defaultExpenseAccountCode = try c.decodeIfPresent(String.self, forKey: .defaultExpenseAccountCode) ?? "429"
        expenseTaxType = try c.decodeIfPresent(String.self, forKey: .expenseTaxType) ?? "INPUT"
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "AUD"
        taxLabel = try c.decodeIfPresent(String.self, forKey: .taxLabel) ?? "GST"
        taxRate = try c.decodeIfPresent(Double.self, forKey: .taxRate) ?? 0.10
        taxType = try c.decodeIfPresent(String.self, forKey: .taxType) ?? "OUTPUT"
        taxRegistrationLabel = try c.decodeIfPresent(String.self, forKey: .taxRegistrationLabel) ?? "ABN"
        invoiceTitle = try c.decodeIfPresent(String.self, forKey: .invoiceTitle) ?? ""
    }
    init() {}

    /// Sensible tax defaults per currency. Users can edit everything after.
    /// Includes the INPUT (expense) counterpart of each country's tax type.
    static func taxDefaults(forCurrency code: String)
        -> (taxLabel: String, taxRate: Double, taxType: String,
            expenseTaxType: String, registrationLabel: String) {
        switch code.uppercased() {
        case "AUD": return ("GST", 0.10, "OUTPUT", "INPUT", "ABN")
        case "NZD": return ("GST", 0.15, "OUTPUT2", "INPUT2", "GST No")
        case "GBP": return ("VAT", 0.20, "OUTPUT2", "INPUT2", "VAT No")
        case "EUR": return ("VAT", 0.19, "OUTPUT", "INPUT", "VAT No")
        case "CAD": return ("GST/HST", 0.05, "OUTPUT", "INPUT", "GST/HST No")
        case "SGD": return ("GST", 0.09, "OUTPUT", "INPUT", "GST Reg No")
        case "USD": return ("Sales Tax", 0.0, "EXEMPTOUTPUT", "EXEMPTINPUT", "EIN")
        default:    return ("Tax", 0.0, "EXEMPTOUTPUT", "EXEMPTINPUT", "Tax ID")
        }
    }

    /// The currencies we surface in the Business picker (editable after).
    static let commonCurrencies = ["AUD", "NZD", "GBP", "EUR", "USD", "CAD", "SGD", "JPY", "HKD", "CHF"]

    /// Resolved invoice title for PDF letterheads.
    func resolvedInvoiceTitle(fallbackTaxLabel: String, taxRate: Double) -> String {
        if !invoiceTitle.isEmpty { return invoiceTitle.uppercased() }
        guard taxRate > 0 else { return "INVOICE" }
        let label = fallbackTaxLabel.uppercased()
        return label == "GST" ? "TAX INVOICE" : "\(label) INVOICE"
    }

    static func load() -> BooksSeller {
        guard let data = UserDefaults.standard.data(forKey: "maestrobooks.seller"),
              let seller = try? JSONDecoder().decode(BooksSeller.self, from: data) else {
            return BooksSeller()
        }
        return seller
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "maestrobooks.seller")
        }
    }
}

/// Price-list entry: a reusable product or service the business sells.
/// Selected from pickers in the New Invoice sheet (or by name from agents);
/// selecting one fills description + unit price (+ Xero overrides).
struct BooksProduct: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var details: String?
    var unitPrice: Double
    /// Xero Item Code — unique, required by the Items API. Blank at save
    /// time becomes an auto-slug of the name (Self.itemCode(fromName:)).
    var code: String?
    /// Xero account code override (nil = business default).
    var accountCode: String?
    /// Xero tax type override (nil = invoice default).
    var taxType: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "products"

    enum CodingKeys: String, CodingKey {
        case id, name, code
        case details = "description"
        case unitPrice = "unit_price"
        case accountCode = "account_code"
        case taxType = "tax_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let name = Column(CodingKeys.name)
        static let code = Column(CodingKeys.code)
    }

    /// Xero-safe item code from a display name: "Peer mentor hourly" →
    /// "PEER-MENTOR-HOURLY" (uppercase, hyphenated, 30 chars max).
    static func itemCode(fromName name: String) -> String {
        let slug = name.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(slug.prefix(30))
    }
}

/// Shared "Description | qty | price [| discount%]" item-line parser (agents).
enum BooksItemParser {
    /// Returns (description, quantity, unitAmount, discount%) per item.
    /// 4th pipe optional: "desc | 8 | 70.23 | 10" = 10% off that line.
    static func parse(_ text: String)
        -> [(description: String, quantity: Double, unitAmount: Double, discount: Double)] {
        var items: [(String, Double, Double, Double)] = []
        var pending = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, !parts[0].isEmpty,
               let quantity = Double(parts[1]),
               let price = Double(parts[2].replacingOccurrences(of: "$", with: "")) {
                let description = pending.isEmpty ? parts[0] : pending + " " + parts[0]
                let discount = parts.count > 3
                    ? (Double(parts[3].replacingOccurrences(of: "%", with: "")) ?? 0) : 0
                items.append((description, quantity, price, discount))
                pending = ""
            } else {
                pending = pending.isEmpty ? line : pending + " " + line
            }
        }
        if !pending.isEmpty { items.append((pending, 1, 0, 0)) }
        return items
    }
}

/// Money formatting (AUD-style, 2dp, no locale surprises).
enum BooksMoney {
    static func format(_ value: Double, currency: String = "AUD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_AU")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func plain(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension BooksClient {
    /// Maps a Contacts-framework Contact (see ContactsService) to an invoicing
    /// client. Organization wins over person name by default (invoices usually
    /// bill the entity) — pass `nameOverride` when the user picks a different
    /// display name (e.g. org field used as a personal label/tag). Email and
    /// phone default to the first on the card; overrides win when multiples
    /// exist and the user picked a specific one.
    init(contact: Contact, nameOverride: String? = nil,
         emailOverride: String? = nil, phoneOverride: String? = nil) {
        func chosen(_ override: String?, _ fallback: String?) -> String? {
            let trimmed = override?.trimmingCharacters(in: .whitespaces)
            return (trimmed?.isEmpty == false) ? trimmed : fallback
        }
        let resolvedName = chosen(nameOverride, nil)
            ?? (!contact.organizationName.isEmpty ? contact.organizationName
                : (!contact.fullName.isEmpty ? contact.fullName : contact.displayName))
        let address = contact.addresses.first
        let now = Date()
        self.init(
            id: nil,
            name: resolvedName,
            email: chosen(emailOverride, contact.emailAddresses.first?.value),
            phone: chosen(phoneOverride, contact.phoneNumbers.first?.value),
            poAddressLine1: address?.street.isEmpty == false ? address?.street : nil,
            poAddressLine2: nil,
            poCity: address?.city.isEmpty == false ? address?.city : nil,
            poRegion: address?.state.isEmpty == false ? address?.state : nil,
            poPostalCode: address?.postalCode.isEmpty == false ? address?.postalCode : nil,
            poCountry: address?.country.isEmpty == false ? address?.country : nil,
            taxNumber: nil, notes: nil, xeroID: nil,
            createdAt: now, updatedAt: now)
    }
}
