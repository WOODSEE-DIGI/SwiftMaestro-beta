import Foundation

/// A single item queued for deletion during a free-up-space workflow.
struct DAMCleanupItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var path: String
    var size: Int64
    var addedAt: Date

    init(path: String, size: Int64) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.addedAt = Date()
    }
}

/// Persistent queue of files/folders the user has marked for deletion.
///
/// Stored in `UserDefaults` as a lightweight JSON array so the list survives
/// relaunches and can be shared across MaestroDAM panels.
@MainActor
@Observable
final class DAMCleanupListStore {
    static let shared = DAMCleanupListStore()
    private static let userDefaultsKey = "dam.cleanupList.items"

    private(set) var items: [DAMCleanupItem] = []

    private let lock = NSLock()

    private init() {
        load()
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var count: Int {
        items.count
    }

    /// Adds a path to the cleanup queue, ignoring duplicates.
    func add(path: String) {
        let normalized = (path as NSString).standardizingPath
        lock.lock()
        defer { lock.unlock() }

        guard !items.contains(where: { $0.path == normalized }) else { return }

        let size = directorySize(at: normalized)
        items.append(DAMCleanupItem(path: normalized, size: size))
        save()
    }

    func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll { $0.id == id }
        save()
    }

    func remove(items ids: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([DAMCleanupItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    // MARK: - Size calculation

    /// Returns the recursive size of a path, or 0 if it cannot be read.
    private nonisolated func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        var size: Int64 = 0

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                if let attr = try? FileManager.default.attributesOfItem(atPath: path),
                   let fileSize = attr[.size] as? Int64 {
                    return fileSize
                }
                return 0
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                size += fileSize
            }
        }
        return size
    }
}
