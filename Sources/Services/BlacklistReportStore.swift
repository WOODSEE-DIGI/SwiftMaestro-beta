import Foundation

// MARK: - Blacklist Report Store

/// Local store for pending and published blacklist reports. Persists to
/// UserDefaults; in future this may move to the shared GRDB database.
@MainActor
final class BlacklistReportStore {
    static let shared = BlacklistReportStore()
    private let key = "BlacklistReportStore.reports"

    private init() {}

    func reports() -> [BlacklistReport] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BlacklistReport].self, from: data)) ?? []
    }

    func save(_ report: BlacklistReport) {
        var all = reports()
        if let index = all.firstIndex(where: { $0.id == report.id }) {
            all[index] = report
        } else {
            all.append(report)
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func delete(id: UUID) {
        var all = reports().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
