import Foundation

extension Notification.Name {
    /// Posted (userInfo: ["boardID": uuidString]) when an agent tool mutates a
    /// board's object data on disk, so an open Whiteboard panel reloads the
    /// board instead of later overwriting the agent's edits with its stale
    /// in-memory copy.
    static let whiteboardBoardExternallyModified = Notification.Name("whiteboardBoardExternallyModified")
}

// MARK: - Canvas store

/// Loads and saves canvas board metadata. The PaperKit markup payload is stored
/// as binary data inside each board record.
@Observable
@MainActor
final class WhiteboardStore {

    private(set) var boards: [WhiteboardBoard] = []
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
            boards = try urls.compactMap { url -> WhiteboardBoard? in
                let data = try Data(contentsOf: url)
                return try decoder.decode(WhiteboardBoard.self, from: data)
            }
            .sorted { $0.modified > $1.modified }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createBoard(name: String) -> WhiteboardBoard {
        let now = Date()
        let board = WhiteboardBoard(
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

    func save(_ board: WhiteboardBoard) throws {
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

    func duplicate(_ board: WhiteboardBoard) -> WhiteboardBoard {
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
