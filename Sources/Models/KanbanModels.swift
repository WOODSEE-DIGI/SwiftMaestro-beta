import Foundation
import SwiftUI

// MARK: - Kanban priority

enum KanbanPriority: String, Codable, CaseIterable, Identifiable, Comparable {
    case none = "none"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case urgent = "urgent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .urgent: return .red
        }
    }

    var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .urgent: return 4
        }
    }

    static func < (lhs: KanbanPriority, rhs: KanbanPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Kanban column color

enum KanbanColumnColor: String, Codable, CaseIterable, Identifiable {
    case blue = "blue"
    case green = "green"
    case yellow = "yellow"
    case orange = "orange"
    case red = "red"
    case purple = "purple"
    case gray = "gray"

    var id: String { rawValue }

    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

// MARK: - Kanban card

struct KanbanCard: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var description: String
    var priority: KanbanPriority
    var dueDate: Date?
    var tags: [String]
    var created: Date
    var modified: Date

    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        priority: KanbanPriority = .none,
        dueDate: Date? = nil,
        tags: [String] = [],
        created: Date = Date(),
        modified: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.priority = priority
        self.dueDate = dueDate
        self.tags = tags
        self.created = created
        self.modified = modified
    }

    var isOverdue: Bool {
        guard let dueDate else { return false }
        return dueDate < Date().startOfDay
    }

    var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }
}

// MARK: - Kanban column

struct KanbanColumn: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var cards: [KanbanCard]
    var color: KanbanColumnColor?
    var wipLimit: Int?

    init(
        id: UUID = UUID(),
        title: String,
        cards: [KanbanCard] = [],
        color: KanbanColumnColor? = nil,
        wipLimit: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.cards = cards
        self.color = color
        self.wipLimit = wipLimit
    }
}

// MARK: - Kanban board

struct KanbanBoard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var columns: [KanbanColumn]
    var created: Date
    var modified: Date

    init(
        id: UUID = UUID(),
        name: String,
        columns: [KanbanColumn] = [],
        created: Date = Date(),
        modified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.created = created
        self.modified = modified
    }
}

// MARK: - Helpers

private extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
}
