import Foundation

// MARK: - Canvas store

/// Loads and saves canvas board metadata. The PaperKit markup payload is stored
/// as binary data inside each board record.
@Observable
@MainActor
final class CanvasStore {

    private(set) var boards: [CanvasBoard] = []
    private(set) var error: String?

    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("SwiftMaestro/canvases", isDirectory: true)
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - CRUD

    func loadBoards() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "canvas" }
            boards = try urls.compactMap { url -> CanvasBoard? in
                let data = try Data(contentsOf: url)
                return try decoder.decode(CanvasBoard.self, from: data)
            }
            .sorted { $0.modified > $1.modified }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createBoard(name: String) -> CanvasBoard {
        let now = Date()
        let board = CanvasBoard(
            id: UUID(),
            name: name,
            markupData: nil,
            created: now,
            modified: now
        )
        boards.insert(board, at: 0)
        try? save(board)
        return board
    }

    func save(_ board: CanvasBoard) throws {
        var updated = board
        updated.modified = Date()
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: updated.id))
        if let index = boards.firstIndex(where: { $0.id == updated.id }) {
            boards[index] = updated
        } else {
            boards.insert(updated, at: 0)
        }
        error = nil
    }

    func delete(_ id: UUID) {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            boards.removeAll { $0.id == id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func duplicate(_ board: CanvasBoard) -> CanvasBoard {
        let now = Date()
        var copy = board
        copy.id = UUID()
        copy.name = "\(board.name) Copy"
        copy.created = now
        copy.modified = now
        try? save(copy)
        return copy
    }

    // MARK: - Helpers

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).canvas")
    }
}
