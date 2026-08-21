import Foundation

// MARK: - Canvas board

/// A canvas board backed by PaperKit markup data.
struct WhiteboardBoard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var markupData: Data?
    var created: Date
    var modified: Date
}
