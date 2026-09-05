import Foundation

// MARK: - Sent Ticket Store
//
// Keeps a small local history of diagnostic reports the user has sent so the
// Swift Helper settings tab can show a real ticketing list. Stores only
// non-sensitive metadata: server reference ID, local title, date, and whether
// the user attached media. The actual report payload is never retained.

struct SentTicket: Codable, Identifiable, Sendable {
    let id: String
    let referenceID: String
    let title: String
    let date: Date
    let hadAttachment: Bool
}

@MainActor
final class SentTicketStore {
    static let shared = SentTicketStore()

    private let url: URL
    private var tickets: [SentTicket] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMaestro")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("sent-tickets.json")
        load()
    }

    var allTickets: [SentTicket] {
        tickets.sorted { $0.date > $1.date }
    }

    func record(referenceID: String, title: String, hadAttachment: Bool) {
        let ticket = SentTicket(
            id: UUID().uuidString,
            referenceID: referenceID,
            title: String(title.prefix(200)),
            date: Date(),
            hadAttachment: hadAttachment
        )
        tickets.append(ticket)
        // Keep the last 50 so the list stays small.
        if tickets.count > 50 {
            tickets = tickets.sorted { $0.date > $1.date }.prefix(50).map { $0 }
        }
        save()
    }

    func delete(_ ticket: SentTicket) {
        tickets.removeAll { $0.id == ticket.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SentTicket].self, from: data) else { return }
        tickets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tickets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
