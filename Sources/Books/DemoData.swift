import Foundation

// MARK: - Demo mode content
//
// Fictional, screenshot-safe sample data for demos, marketing screenshots,
// and how-to videos. Lives in a SEPARATE database (books-demo.sqlite) —
// the user's real books are never touched. All names are invented; no real
// people or businesses.
enum DemoData {

    /// The demo business shown on invoice letterheads (in-memory only —
    /// never written to the user's UserDefaults seller profile).
    static var seller: BooksSeller {
        var seller = BooksSeller()
        seller.name = "Harbour & Lane Studio"
        seller.abn = "51 824 753 556"
        seller.address = "Suite 4, 88 Cathedral St, Woolloomooloo NSW 2011"
        seller.email = "hello@harbourlane.example"
        seller.phone = "(02) 9000 4411"
        seller.paymentDetails = "BSB 062-001\nAccount 1042 8891\nHarbour & Lane Studio"
        seller.defaultAccountCode = "200"
        seller.defaultExpenseAccountCode = "429"
        seller.currency = "AUD"
        seller.taxLabel = "GST"
        seller.taxRate = 0.10
        seller.taxType = "OUTPUT"
        seller.expenseTaxType = "INPUT"
        seller.taxRegistrationLabel = "ABN"
        seller.invoiceTitle = ""
        return seller
    }

    /// Seeds the demo database when empty (idempotent — checks client count).
    static func seedIfEmpty(_ db: BooksDatabase) throws {
        guard try db.clients().isEmpty else { return }
        let now = Date()

        // MARK: Clients
        let clientSpecs: [(name: String, email: String, phone: String,
                           street: String, city: String, region: String,
                           postcode: String, tax: String?)] = [
            ("Bluegum Builders Pty Ltd", "accounts@bluegumbuilders.example",
             "(02) 9555 0182", "14 Jarrah Ave", "Leichhardt", "NSW", "2040", "63 117 208 944"),
            ("Fern & Fig Florist", "hello@fernandfig.example",
             "0412 880 345", "3/212 King St", "Newtown", "NSW", "2042", nil),
            ("Sunny Coast Surf School", "bookings@sunnycoastsurf.example",
             "(02) 6680 7721", "45 Lighthouse Rd", "Byron Bay", "NSW", "2481", "74 552 901 338"),
            ("Northern Beaches Vet Clinic", "admin@nbvet.example",
             "(02) 9977 2204", "9 Pittwater Rd", "Manly", "NSW", "2095", "88 460 112 775"),
            ("Copper Kettle Café", "kat@copperkettle.example",
             "(02) 4782 1190", "126 Bathurst Rd", "Katoomba", "NSW", "2780", nil),
        ]
        var clientIDs: [String: Int64] = [:]
        for spec in clientSpecs {
            var client = BooksClient.blank
            client.name = spec.name
            client.email = spec.email
            client.phone = spec.phone
            client.poAddressLine1 = spec.street
            client.poCity = spec.city
            client.poRegion = spec.region
            client.poPostalCode = spec.postcode
            client.poCountry = "Australia"
            client.taxNumber = spec.tax
            client = try db.saveClient(&client)
            clientIDs[spec.name] = client.id
        }

        // MARK: Price list
        let productSpecs: [(name: String, details: String?, price: Double)] = [
            ("Design consultation", "Brand & visual consultation (hourly)", 180),
            ("Brand identity package", "Logo, palette, typography & guidelines", 2400),
            ("Support session", "One-on-one support session (hourly)", 70.23),
            ("Site visit", "On-site visit within metro area", 150),
        ]
        for spec in productSpecs {
            var product = BooksProduct(
                id: nil, name: spec.name, details: spec.details, unitPrice: spec.price,
                code: nil, accountCode: nil, taxType: nil,
                createdAt: now, updatedAt: now)
            _ = try db.saveProduct(&product)
        }

        // MARK: Invoices (mixed statuses for the screenshots)
        func invoice(
            _ client: String,
            items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
            dueDays: Int
        ) throws -> BooksInvoice {
            try db.createInvoice(
                clientID: clientIDs[client]!,
                items: items,
                dueDate: Calendar.current.date(byAdding: .day, value: dueDays, to: now),
                notes: nil, accountCode: "200")
        }

        // PAID ×2 (with full payments recorded)
        let paid1 = try invoice("Bluegum Builders Pty Ltd", items: [
            ("Brand identity package", 1, 2400, 0),
            ("Design consultation", 2, 180, 0),
        ], dueDays: -20)
        try db.setInvoiceStatus(paid1.id!, .authorised)
        try db.recordPayment(invoiceID: paid1.id!, amount: 3036.00, method: "bank transfer", note: nil)

        let paid2 = try invoice("Copper Kettle Café", items: [
            ("Design consultation", 1, 180, 0),
        ], dueDays: -8)
        try db.setInvoiceStatus(paid2.id!, .authorised)
        try db.recordPayment(invoiceID: paid2.id!, amount: 198.00, method: "card", note: nil)

        // AUTHORISED ×2 — one OVERDUE (drives the red overdue badge)
        let overdue = try invoice("Sunny Coast Surf School", items: [
            ("Support session", 6, 70.23, 10),
            ("Site visit", 1, 150, 0),
        ], dueDays: -6)
        try db.setInvoiceStatus(overdue.id!, .authorised)

        let sent = try invoice("Northern Beaches Vet Clinic", items: [
            ("Support session", 8, 70.23, 0),
        ], dueDays: 14)
        try db.setInvoiceStatus(sent.id!, .authorised)

        // DRAFT + VOIDED
        _ = try invoice("Fern & Fig Florist", items: [
            ("Brand identity package", 1, 2400, 0),
        ], dueDays: 14)

        let voided = try invoice("Bluegum Builders Pty Ltd", items: [
            ("Site visit", 1, 150, 0),
        ], dueDays: 7)
        try db.setInvoiceStatus(voided.id!, .voided)

        // MARK: Expenses
        func expense(
            _ supplier: String, _ description: String, _ amount: Double,
            _ status: BooksInvoiceStatus, reference: String? = nil
        ) throws {
            var entry = BooksExpense(
                id: nil, supplier: supplier, expenseDescription: description,
                reference: reference, accountCode: "429", issueDate: now,
                statusRaw: status.rawValue, currency: "AUD", taxRate: 0.10,
                taxType: "INPUT", subtotal: amount, notes: nil, xeroID: nil,
                createdAt: now, updatedAt: now)
            _ = try db.saveExpense(&entry)
        }
        try expense("Officeworks", "Printer paper & toner", 45.00, .paid, reference: "OW-7741")
        try expense("Adobe", "Creative Cloud subscription", 89.99, .authorised, reference: "ADB-2026-07")
        try expense("Bunnings", "Studio materials", 132.50, .draft)
    }
}
