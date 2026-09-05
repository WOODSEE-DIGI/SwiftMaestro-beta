import Foundation

// MARK: - MaestroDB Demo Data
//
// Video/screenshot-safe demo base, seeded on first entry to demo mode.
// Follows the DemoData.seedIfEmpty pattern from MaestroBooks — fictional
// clients/projects only, aligned with the SwiftMaestroDemo pack's world.

enum MaestroDBDemoData {

    /// Seed the demo base unless it's already present. Idempotent by base
    /// name — a partially-used demo database (user created their own demo
    /// bases first) still gets the full seed on the next entry.
    static func seedIfEmpty(_ database: MaestroDBDatabase) throws {
        let existingNames = try database.bases().map(\.name)
        guard !existingNames.contains("Production Jobs") else { return }

        let base = try database.createBase(name: "Production Jobs", icon: "film")

        // MARK: Jobs table
        let jobs = try database.createTable(baseID: base.id, name: "Jobs")
        let titleField = try database.addField(tableID: jobs.id, name: "Job", type: .text)
        let clientField = try database.addField(
            tableID: jobs.id, name: "Client", type: .select,
            options: ["Demo Client A", "Demo Client B", "Demo Client C", "Demo Client D"])
        let statusField = try database.addField(
            tableID: jobs.id, name: "Status", type: .select,
            options: ["Booked", "Shooting", "Wrangling", "Delivered", "Archived"])
        let shootDateField = try database.addField(tableID: jobs.id, name: "Shoot date", type: .date)
        let priorityField = try database.addField(tableID: jobs.id, name: "Priority", type: .rating)
        let paidField = try database.addField(tableID: jobs.id, name: "Delivered", type: .checkbox)
        let linkField = try database.addField(tableID: jobs.id, name: "Job link", type: .url)
        let notesField = try database.addField(tableID: jobs.id, name: "Notes", type: .longText)

        let day: TimeInterval = 86_400
        let jobsSeed: [(String, String, String, Int, Int, Bool, String)] = [
            ("Brand identity shoot",  "Demo Client A",          "Shooting",   3, 5, false, "https://example.com/jobs/101"),
            ("Spring menu photos",    "Demo Client D",          "Wrangling",  1, 4, false, ""),
            ("Surf school promos",    "Demo Client C",          "Booked",     9, 3, false, ""),
            ("Shopfront refresh",     "Demo Client B",          "Delivered", -6, 4, true,  "https://example.com/refresh"),
            ("Office portraits",      "Demo Client A",          "Delivered", -13, 2, true, ""),
            ("Winter specials board", "Demo Client D",          "Booked",    14, 3, false, ""),
        ]
        for (title, client, status, dayOffset, priority, delivered, link) in jobsSeed {
            var values: [String: String] = [
                titleField.id: title,
                clientField.id: client,
                statusField.id: status,
                priorityField.id: String(priority),
                paidField.id: DBRow.store(delivered),
            ]
            values[shootDateField.id] = DBRow.store(Date().addingTimeInterval(Double(dayOffset) * day))
            if !link.isEmpty { values[linkField.id] = link }
            if title == "Brand identity shoot" {
                values[notesField.id] = "Two locations — main studio and secondary office. Drone permits confirmed for Thursday."
            }
            try database.addRow(tableID: jobs.id, values: values)
        }

        // MARK: Gear table
        let gear = try database.createTable(baseID: base.id, name: "Gear Register")
        let itemField = try database.addField(tableID: gear.id, name: "Item", type: .text)
        let categoryField = try database.addField(
            tableID: gear.id, name: "Category", type: .select,
            options: ["Camera", "Lens", "Support", "Storage", "Audio"])
        let conditionField = try database.addField(tableID: gear.id, name: "Condition", type: .rating)
        let servicedField = try database.addField(tableID: gear.id, name: "Last serviced", type: .date)
        let availableField = try database.addField(tableID: gear.id, name: "Available", type: .checkbox)

        let gearSeed: [(String, String, Int, Int, Bool)] = [
            ("Sony A7R IV",          "Camera",  5, -90,  true),
            ("24-70mm f/2.8 GM",     "Lens",    5, -90,  true),
            ("70-200mm f/2.8 GM II", "Lens",    4, -180, true),
            ("Travel tripod",        "Support", 3, -365, true),
            ("CFexpress 640GB ×4",   "Storage", 5, -30,  true),
            ("Wireless lavalier set","Audio",   4, -120, false),
        ]
        for (item, category, condition, servicedOffset, available) in gearSeed {
            try database.addRow(tableID: gear.id, values: [
                itemField.id: item,
                categoryField.id: category,
                conditionField.id: String(condition),
                servicedField.id: DBRow.store(Date().addingTimeInterval(Double(servicedOffset) * day)),
                availableField.id: DBRow.store(available),
            ])
        }

        NSLog("[MaestroDB] Demo base seeded: Production Jobs (Jobs + Gear Register)")
    }
}
