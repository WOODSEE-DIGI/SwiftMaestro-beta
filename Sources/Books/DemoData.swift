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
        seller.abn = "12 345 678 901"
        seller.address = "Suite 1, 123 Example St, Sampleville NSW 2000"
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

    /// Seeds the demo database. Always starts from a clean schema so updated
    /// demo datasets are applied without manual file cleanup.
    static func seedIfEmpty(_ db: BooksDatabase) throws {
        try db.resetDemoDatabase()
        let now = Date()
        let calendar = Calendar.current

        func seedSection(_ name: String, operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                NSLog("[DemoData] Section '%@' failed: %@", name, String(describing: error))
            }
        }

        // MARK: - Chart of Accounts
        // Migration v5 seeds a small default COA. We upsert every row so the
        // demo dataset is coherent and never trips the unique-code constraint.
        seedSection("Chart of Accounts") {
            let existingAccounts = try db.accounts()
            var accountsByCode: [String: BooksAccount] = Dictionary(
                uniqueKeysWithValues: existingAccounts.map { ($0.code, $0) })

            func ensureAccount(
                code: String, name: String, type: BooksAccountType,
                taxType: String, taxLabel: String, isBank: Bool,
                openingBalance: Double, description: String?
            ) throws {
                var account = accountsByCode[code] ?? BooksAccount.blank
                account.code = code
                account.name = name
                account.type = type
                account.taxType = taxType
                account.taxLabel = taxLabel
                account.isBank = isBank
                account.openingBalance = openingBalance
                account.balance = openingBalance
                account.description = description
                _ = try db.saveAccount(&account)
            }

            try ensureAccount(code: "100", name: "Business Bank Account", type: .asset,
                              taxType: "NONE", taxLabel: "None", isBank: true,
                              openingBalance: 12500, description: "Main operating account")
            try ensureAccount(code: "120", name: "Accounts Receivable", type: .asset,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 0, description: "Money owed by customers")
            try ensureAccount(code: "150", name: "Office Equipment", type: .asset,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 3500, description: "Computers, cameras, furniture")
            try ensureAccount(code: "200", name: "Sales", type: .income,
                              taxType: "OUTPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "General sales revenue")
            try ensureAccount(code: "210", name: "Design Income", type: .income,
                              taxType: "OUTPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Design project income")
            try ensureAccount(code: "300", name: "Accounts Payable", type: .liability,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 0, description: "Money owed to suppliers")
            try ensureAccount(code: "310", name: "GST Payable", type: .liability,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 0, description: "Net GST owed to the ATO")
            try ensureAccount(code: "400", name: "Owner's Capital", type: .equity,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 20000, description: "Owner investment")
            try ensureAccount(code: "410", name: "Current Year Earnings", type: .equity,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 0, description: "Retained earnings")
            try ensureAccount(code: "429", name: "Software Subscriptions", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "SaaS and creative tools")
            try ensureAccount(code: "500", name: "Rent", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Studio rent")
            try ensureAccount(code: "520", name: "Office Supplies", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Stationery and consumables")
            try ensureAccount(code: "530", name: "Contractor Fees", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Freelancers and subcontractors")
            try ensureAccount(code: "540", name: "Marketing", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Ads, events, sponsorships")
            try ensureAccount(code: "610", name: "General Expenses", type: .expense,
                              taxType: "INPUT", taxLabel: "GST", isBank: false,
                              openingBalance: 0, description: "Miscellaneous expenses")
            try ensureAccount(code: "800", name: "Credit Card", type: .liability,
                              taxType: "NONE", taxLabel: "None", isBank: true,
                              openingBalance: 0, description: "Business credit card")
            try ensureAccount(code: "820", name: "Savings Account", type: .asset,
                              taxType: "NONE", taxLabel: "None", isBank: true,
                              openingBalance: 5000, description: "Reserve savings")
            try ensureAccount(code: "900", name: "Owner Equity", type: .equity,
                              taxType: "NONE", taxLabel: "None", isBank: false,
                              openingBalance: 0, description: "Opening equity")
        }

        // MARK: - Clients
        var clientIDs: [String: Int64] = [:]
        seedSection("Clients") {
            let clientSpecs: [(name: String, email: String, phone: String,
                               street: String, city: String, region: String,
                               postcode: String, tax: String?,
                               customFields: [String: String]?)] = [
                ("Bluegum Builders Pty Ltd", "accounts@bluegumbuilders.example",
                 "(02) 9555 0182", "14 Jarrah Ave", "Leichhardt", "NSW", "2040", "63 117 208 944",
                 ["Website": "bluegumbuilders.example", "Referrer": "Word of mouth"]),
                ("Fern & Fig Florist", "hello@fernandfig.example",
                 "0412 880 345", "3/212 King St", "Newtown", "NSW", "2042", nil, nil),
                ("Sunny Coast Surf School", "bookings@sunnycoastsurf.example",
                 "(02) 6680 7721", "45 Lighthouse Rd", "Byron Bay", "NSW", "2481", "74 552 901 338",
                 ["Website": "sunnycoastsurf.example", "Season": "Summer peak"]),
                ("Northern Beaches Vet Clinic", "admin@nbvet.example",
                 "(02) 9977 2204", "9 Pittwater Rd", "Manly", "NSW", "2095", "88 460 112 775", nil),
                ("Copper Kettle Café", "kat@copperkettle.example",
                 "(02) 4782 1190", "126 Bathurst Rd", "Katoomba", "NSW", "2780", nil,
                 ["Opening Hours": "Mon–Sun 07:00–15:00"]),
                ("Wild Coast Photography", "hello@wildcoast.example",
                 "0418 221 903", "Unit 2, 77 Ocean Rd", "Broulee", "NSW", "2537", "90 123 456 789", nil),
            ]
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
                client.customFields = spec.customFields
                client = try db.saveClient(&client)
                clientIDs[spec.name] = client.id
            }
        }

        // MARK: - Price list
        seedSection("Price list") {
            let productSpecs: [(name: String, details: String?, price: Double, code: String?)] = [
                ("Design consultation", "Brand & visual consultation (hourly)", 180, "CONSULT"),
                ("Brand identity package", "Logo, palette, typography & guidelines", 2400, "BRAND"),
                ("Support session", "One-on-one support session (hourly)", 70.23, "SUPPORT"),
                ("Site visit", "On-site visit within metro area", 150, "SITE"),
                ("Social media kit", "10 posts + 2 story templates", 850, "SOCIAL"),
                ("Website landing page", "Single-page design + assets", 1650, "LANDING"),
            ]
            for spec in productSpecs {
                var product = BooksProduct(
                    id: nil, name: spec.name, details: spec.details, unitPrice: spec.price,
                    code: spec.code, accountCode: nil, taxType: nil,
                    createdAt: now, updatedAt: now)
                _ = try db.saveProduct(&product)
            }
        }

        // MARK: - Invoices (mixed statuses for the screenshots)
        seedSection("Invoices") {
            func invoice(
                _ client: String,
                items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
                dueDays: Int,
                notes: String? = nil
            ) throws -> BooksInvoice {
                try db.createInvoice(
                    clientID: clientIDs[client]!,
                    items: items,
                    dueDate: calendar.date(byAdding: .day, value: dueDays, to: now),
                    notes: notes, accountCode: "200")
            }

            // PAID ×3 (with full payments recorded)
            let paid1 = try invoice("Bluegum Builders Pty Ltd", items: [
                ("Brand identity package", 1, 2400, 0),
                ("Design consultation", 2, 180, 0),
            ], dueDays: -20, notes: "Paid via bank transfer")
            try db.setInvoiceStatus(paid1.id!, .authorised)
            try db.recordPayment(invoiceID: paid1.id!, amount: 3036.00, method: "bank transfer", note: nil)

            let paid2 = try invoice("Copper Kettle Café", items: [
                ("Design consultation", 1, 180, 0),
            ], dueDays: -8)
            try db.setInvoiceStatus(paid2.id!, .authorised)
            try db.recordPayment(invoiceID: paid2.id!, amount: 198.00, method: "card", note: nil)

            let paid3 = try invoice("Wild Coast Photography", items: [
                ("Social media kit", 1, 850, 0),
                ("Website landing page", 1, 1650, 0),
            ], dueDays: -14)
            try db.setInvoiceStatus(paid3.id!, .authorised)
            try db.recordPayment(invoiceID: paid3.id!, amount: 2750.00, method: "bank transfer", note: nil)

            // AUTHORISED ×3 — one OVERDUE (drives the red overdue badge)
            let overdue = try invoice("Sunny Coast Surf School", items: [
                ("Support session", 6, 70.23, 10),
                ("Site visit", 1, 150, 0),
            ], dueDays: -6)
            try db.setInvoiceStatus(overdue.id!, .authorised)

            let sent = try invoice("Northern Beaches Vet Clinic", items: [
                ("Support session", 8, 70.23, 0),
            ], dueDays: 14)
            try db.setInvoiceStatus(sent.id!, .authorised)

            let sent2 = try invoice("Bluegum Builders Pty Ltd", items: [
                ("Website landing page", 1, 1650, 0),
                ("Design consultation", 3, 180, 0),
            ], dueDays: 21)
            try db.setInvoiceStatus(sent2.id!, .authorised)

            // DRAFT ×2 + VOIDED
            _ = try invoice("Fern & Fig Florist", items: [
                ("Brand identity package", 1, 2400, 0),
            ], dueDays: 14)

            _ = try invoice("Wild Coast Photography", items: [
                ("Site visit", 2, 150, 0),
            ], dueDays: 7)

            let voided = try invoice("Bluegum Builders Pty Ltd", items: [
                ("Site visit", 1, 150, 0),
            ], dueDays: 7)
            try db.setInvoiceStatus(voided.id!, .voided)
        }

        // MARK: - Expenses
        seedSection("Expenses") {
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
            try expense("Office Supplies Co", "Printer paper & toner", 45.00, .paid, reference: "OW-7741")
            try expense("Software Subscriptions Inc", "Creative Cloud subscription", 89.99, .authorised, reference: "ADB-2026-07")
            try expense("Hardware Warehouse", "Studio materials", 132.50, .draft)
            try expense("CoWorking Space", "Monthly studio rent", 880.00, .paid, reference: "WW-2026-08")
            try expense("Social Ads Platform", "Instagram ad campaign", 250.00, .authorised, reference: "META-4412")
            try expense("Freelance Marketplace", "Freelance illustrator", 600.00, .paid, reference: "UPW-9921")
        }

        // MARK: - Suppliers
        var supplierIDs: [String: Int64] = [:]
        seedSection("Suppliers") {
            let supplierSpecs: [(name: String, email: String?, phone: String?,
                                 street: String?, city: String?, region: String?,
                                 postcode: String?, accountCode: String?, paymentTerms: String?)] = [
                ("Office Supplies Co", "accounts@officesupplies.example", "1300 111 222",
                 "2365 Rutland St", "Balcatta", "WA", "6021", "520", "30"),
                ("Software Subscriptions Inc", "billing@softwaresubs.example", "1800 222 333",
                 "345 Park Ave", "San Jose", "CA", "95110", "429", "30"),
                ("Hardware Warehouse", "trade@hardwarewarehouse.example", "(02) 9000 1111",
                 "1-5 McCauley St", "Matraville", "NSW", "2036", "520", "EOM"),
                ("IT Services Provider", "invoices@itservices.example", "(02) 9000 2222",
                 "Level 2, 44 Pitt St", "Sydney", "NSW", "2000", "429", "14"),
                ("CoWorking Space", "billing@coworkingspace.example", "1800 444 555",
                 "580 George St", "Sydney", "NSW", "2000", "500", "Monthly"),
                ("Social Ads Platform", "billing@socialads.example", nil,
                 nil, nil, nil, nil, "540", "Monthly"),
                ("Freelance Marketplace", "payments@freelancemarket.example", nil,
                 nil, nil, nil, nil, "530", "On receipt"),
            ]
            for spec in supplierSpecs {
                var supplier = BooksSupplier.blank
                supplier.name = spec.name
                supplier.email = spec.email
                supplier.phone = spec.phone
                supplier.addressLine1 = spec.street
                supplier.city = spec.city
                supplier.region = spec.region
                supplier.postalCode = spec.postcode
                supplier.country = spec.region == "CA" ? "United States" : "Australia"
                supplier.defaultExpenseAccountCode = spec.accountCode
                supplier.paymentTerms = spec.paymentTerms
                supplier = try db.saveSupplier(&supplier)
                supplierIDs[spec.name] = supplier.id
            }
        }

        // MARK: - Bills (linked to suppliers)
        seedSection("Bills") {
            func bill(
                _ supplier: String,
                items: [(description: String, quantity: Double, unitAmount: Double, discount: Double)],
                dueDays: Int,
                accountCode: String,
                notes: String? = nil
            ) throws -> BooksBill {
                try db.createBill(
                    supplierID: supplierIDs[supplier]!,
                    items: items,
                    dueDate: calendar.date(byAdding: .day, value: dueDays, to: now),
                    notes: notes, accountCode: accountCode)
            }

            let bill1 = try bill("Software Subscriptions Inc",
                items: [(description: "Creative Cloud — annual", quantity: 1, unitAmount: 899.90, discount: 0)],
                dueDays: 30, accountCode: "429", notes: "Annual subscription")
            try db.setBillStatus(bill1.id!, .awaitingPayment)

            let bill2 = try bill("Office Supplies Co",
                items: [
                    (description: "A4 paper", quantity: 5, unitAmount: 9.00, discount: 0),
                    (description: "Toner", quantity: 1, unitAmount: 120.00, discount: 10)
                ],
                dueDays: 14, accountCode: "520")
            try db.setBillStatus(bill2.id!, .paid)

            let bill3 = try bill("CoWorking Space",
                items: [(description: "August studio rent", quantity: 1, unitAmount: 880.00, discount: 0)],
                dueDays: -5, accountCode: "500")
            try db.setBillStatus(bill3.id!, .awaitingPayment)

            let bill4 = try bill("Social Ads Platform",
                items: [(description: "Instagram ad campaign", quantity: 1, unitAmount: 250.00, discount: 0)],
                dueDays: 7, accountCode: "540")
            try db.setBillStatus(bill4.id!, .awaitingPayment)

            let bill5 = try bill("Hardware Warehouse",
                items: [(description: "Studio materials", quantity: 1, unitAmount: 132.50, discount: 0)],
                dueDays: 14, accountCode: "520")
            try db.setBillStatus(bill5.id!, .draft)

            let bill6 = try bill("Freelance Marketplace",
                items: [(description: "Freelance illustrator", quantity: 1, unitAmount: 600.00, discount: 0)],
                dueDays: -12, accountCode: "530")
            try db.setBillStatus(bill6.id!, .paid)
        }

        // MARK: - Journal entries
        seedSection("Journal entries") {
            func journal(
                reference: String,
                memo: String,
                dateOffsetDays: Int,
                lines: [(code: String, debit: Double, credit: Double, description: String)]
            ) throws {
                var entry = BooksJournalEntry(
                    id: nil,
                    date: calendar.date(byAdding: .day, value: dateOffsetDays, to: now) ?? now,
                    reference: reference,
                    memo: memo,
                    currency: "AUD",
                    createdAt: now, updatedAt: now)
                let journalLines = lines.map {
                    BooksJournalLine(id: nil, journalEntryID: 0, accountCode: $0.code,
                                     debit: $0.debit, credit: $0.credit, description: $0.description)
                }
                _ = try db.saveJournalEntry(&entry, lines: journalLines)
            }

            try journal(reference: "JE-001", memo: "Opening balances", dateOffsetDays: -90, lines: [
                ("120", 5000, 0, "Starting accounts receivable"),
                ("150", 3500, 0, "Office equipment"),
                ("400", 0, 8500, "Owner capital contribution")
            ])

            try journal(reference: "JE-002", memo: "Monthly rent allocation", dateOffsetDays: -30, lines: [
                ("500", 880, 0, "August studio rent"),
                ("100", 0, 880, "Bank payment")
            ])

            try journal(reference: "JE-003", memo: "Software Subscriptions Inc annual subscription", dateOffsetDays: -15, lines: [
                ("429", 899.90, 0, "Creative Cloud annual"),
                ("310", 89.99, 0, "GST input"),
                ("100", 0, 989.89, "Bank payment")
            ])

            try journal(reference: "JE-004", memo: "Adjust A/R for paid invoices", dateOffsetDays: -5, lines: [
                ("100", 3036, 0, "Bank receipt — Bluegum Builders"),
                ("120", 0, 3036, "Reduce accounts receivable")
            ])
        }

        // MARK: - CRM Leads
        var leadIDs: [String: Int64] = [:]
        seedSection("CRM Leads") {
            let leadSpecs: [(name: String, company: String?, email: String?, phone: String?,
                             source: String?, estimatedValue: Double?, status: BooksCRMLead.LeadStatus,
                             tax: String?, country: String?, notes: String?)] = [
                ("Example Contact A", "Example Market Co", "contact@examplemarket.example", "0400 111 222",
                 "Website enquiry", 4500, .qualified, nil, "Australia",
                 "Wants rebrand for 3 store locations"),
                ("Example Contact B", nil, "contact@examplecontactb.example", "(02) 9000 3333",
                 "Referral", 1200, .contacted, nil, "Australia",
                 "Solo architect needing portfolio site"),
                ("Creative Studio Co", "Creative Studio Co", "studio@creativestudio.example", "0400 333 444",
                 "Instagram", 6800, .new, "71 234 567 890", "Australia",
                 "Jewellery brand, interested in packaging design"),
                ("Dental Practice Example", "Dental Practice Example", "admin@dentalpractice.example", "(02) 9000 4444",
                 "Cold outreach", 3200, .unqualified, nil, "Australia",
                 "No budget this quarter — follow up in 6 months"),
                ("Fitness Centre Example", "Fitness Centre Example", "hello@fitnesscentre.example", "0400 555 666",
                 "Trade show", 9500, .qualified, nil, "Australia",
                 "Multi-location gym chain — signage + social templates"),
            ]
            for spec in leadSpecs {
                var lead = BooksCRMLead.blank
                lead.name = spec.name
                lead.company = spec.company
                lead.email = spec.email
                lead.phone = spec.phone
                lead.source = spec.source
                lead.estimatedValue = spec.estimatedValue
                lead.status = spec.status
                lead.taxNumber = spec.tax
                lead.country = spec.country
                lead.notes = spec.notes
                lead = try db.saveCRMLead(&lead)
                leadIDs[spec.name] = lead.id
            }
        }

        // MARK: - CRM Opportunities
        var opportunityIDs: [String: Int64] = [:]
        seedSection("CRM Opportunities") {
            // Re-read IDs from the database instead of relying on captured
            // dictionaries, which can be empty if a previous section failed or
            // if closure capture behaves unexpectedly.
            let leadMap: [String: Int64] = Dictionary(
                uniqueKeysWithValues: try db.crmLeads().compactMap { lead -> (String, Int64)? in
                    guard let id = lead.id else { return nil }
                    return (lead.name, id)
                })
            let clientMap: [String: Int64] = Dictionary(
                uniqueKeysWithValues: try db.clients().compactMap { client -> (String, Int64)? in
                    guard let id = client.id else { return nil }
                    return (client.name, id)
                })
            NSLog("[DemoData] Opportunity lookup maps: leads=%@ clients=%@",
                  leadMap.keys.sorted().joined(separator: ","),
                  clientMap.keys.sorted().joined(separator: ","))

            let opportunitySpecs: [(
                title: String,
                leadName: String?, clientName: String?,
                stage: BooksCRMOpportunity.OpportunityStage,
                value: Double, probability: Int,
                closeDays: Int, notes: String?
            )] = [
                ("Brightside rebrand", "Example Contact A", nil, .negotiation, 4500, 75, 14,
                 "Proposal sent; waiting on final approval"),
                ("Fitness Centre Example campaign", "Fitness Centre Example", nil, .proposal, 9500, 50, 30,
                 "Competing with one other agency"),
                ("Vet clinic support retainer", nil, "Northern Beaches Vet Clinic", .closedWon, 7200, 100, -10,
                 "Won — monthly support starting next quarter"),
                ("Harriet packaging design", "Creative Studio Co", nil, .qualified, 6800, 40, 45,
                 "Mood boards approved; quote pending"),
                ("Bluegum website revamp", nil, "Bluegum Builders Pty Ltd", .negotiation, 8500, 60, 21,
                 "Second round of wireframes"),
            ]
            for spec in opportunitySpecs {
                var opp = BooksCRMOpportunity.blank
                opp.title = spec.title
                if let leadName = spec.leadName {
                    opp.leadID = leadMap[leadName]
                }
                if let clientName = spec.clientName {
                    opp.clientID = clientMap[clientName]
                }
                opp.stage = spec.stage
                opp.value = spec.value
                opp.probability = spec.probability
                opp.expectedCloseDate = calendar.date(byAdding: .day, value: spec.closeDays, to: now)
                opp.notes = spec.notes
                NSLog("[DemoData] Creating opportunity '%@' lead=%@(%@) client=%@(%@)",
                      spec.title,
                      spec.leadName ?? "nil", opp.leadID.map(String.init) ?? "nil",
                      spec.clientName ?? "nil", opp.clientID.map(String.init) ?? "nil")
                opp = try db.saveCRMOpportunity(&opp)
                opportunityIDs[spec.title] = opp.id
            }
        }

        // MARK: - CRM Activities
        seedSection("CRM Activities") {
            // Use fresh ID maps from the database for the same robustness reason
            // as the opportunities section.
            let activityLeadMap: [String: Int64] = Dictionary(
                uniqueKeysWithValues: try db.crmLeads().compactMap { lead -> (String, Int64)? in
                    guard let id = lead.id else { return nil }
                    return (lead.name, id)
                })
            let activityClientMap: [String: Int64] = Dictionary(
                uniqueKeysWithValues: try db.clients().compactMap { client -> (String, Int64)? in
                    guard let id = client.id else { return nil }
                    return (client.name, id)
                })

            func activity(kind: BooksCRMActivity.Kind, contactKind: String, contactID: Int64,
                          subject: String, notes: String?, dueOffsetDays: Int?, completed: Bool) throws {
                var a = BooksCRMActivity.blank
                a.kind = kind
                a.contactKind = contactKind
                a.contactID = contactID
                a.subject = subject
                a.notes = notes
                if let offset = dueOffsetDays {
                    a.dueDate = calendar.date(byAdding: .day, value: offset, to: now)
                }
                if completed {
                    a.completedDate = calendar.date(byAdding: .day, value: dueOffsetDays ?? 0, to: now)
                }
                _ = try db.saveCRMActivity(&a)
            }

            func leadID(_ name: String) -> Int64 {
                guard let id = activityLeadMap[name] else {
                    NSLog("[DemoData] Missing lead ID for '%@'", name)
                    return 0
                }
                return id
            }
            func clientID(_ name: String) -> Int64 {
                guard let id = activityClientMap[name] else {
                    NSLog("[DemoData] Missing client ID for '%@'", name)
                    return 0
                }
                return id
            }

            // Lead activities
            try activity(kind: .email, contactKind: "lead",
                         contactID: leadID("Example Contact A"),
                         subject: "Intro call recap", notes: "Sent capabilities deck",
                         dueOffsetDays: -5, completed: true)
            try activity(kind: .task, contactKind: "lead",
                         contactID: leadID("Example Contact A"),
                         subject: "Send proposal", notes: "Include 3-tier pricing",
                         dueOffsetDays: 1, completed: false)
            try activity(kind: .call, contactKind: "lead",
                         contactID: leadID("Example Contact B"),
                         subject: "Portfolio requirements", notes: "Needs CMS training",
                         dueOffsetDays: -2, completed: true)
            try activity(kind: .meeting, contactKind: "lead",
                         contactID: leadID("Fitness Centre Example"),
                         subject: "Creative pitch", notes: "Present 2 concept routes",
                         dueOffsetDays: 4, completed: false)
            try activity(kind: .note, contactKind: "lead",
                         contactID: leadID("Dental Practice Example"),
                         subject: "Budget freeze", notes: "Re-engage in February",
                         dueOffsetDays: 180, completed: false)

            // Client activities
            try activity(kind: .email, contactKind: "client",
                         contactID: clientID("Bluegum Builders Pty Ltd"),
                         subject: "Wireframe feedback", notes: "Likes route B",
                         dueOffsetDays: -3, completed: true)
            try activity(kind: .task, contactKind: "client",
                         contactID: clientID("Sunny Coast Surf School"),
                         subject: "Follow up overdue invoice", notes: "Call after friendly reminder",
                         dueOffsetDays: 0, completed: false)
            try activity(kind: .call, contactKind: "client",
                         contactID: clientID("Northern Beaches Vet Clinic"),
                         subject: "Retainer renewal", notes: "12-month term agreed",
                         dueOffsetDays: -10, completed: true)

            // Opportunity-related activity stored against the lead so it surfaces
            // in the unified activity list (activities are aggregated by lead/client).
            try activity(kind: .task, contactKind: "lead",
                         contactID: leadID("Example Contact A"),
                         subject: "Prepare Brightside contract", notes: "Use standard T&Cs",
                         dueOffsetDays: 2, completed: false)
        }
    }
}
