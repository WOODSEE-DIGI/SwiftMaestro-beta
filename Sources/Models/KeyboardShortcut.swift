import Foundation
import SwiftUI

/// Represents a user-customizable keyboard shortcut.
struct KeyboardShortcut: Identifiable, Codable, Equatable, Hashable {
    /// Stable action identifier, e.g. "newChat", "sendMessage".
    let id: String

    /// Human-readable title shown in settings.
    var title: String

    /// Optional detailed description.
    var description: String?

    /// Default key combination. Immutable once defined.
    let defaultCombination: KeyCombination

    /// Current key combination (may equal default or a user override).
    var currentCombination: KeyCombination

    /// Scope in which the shortcut must be unique.
    var scope: Scope

    /// Whether the user is allowed to change this shortcut.
    var isEditable: Bool

    enum Scope: String, Codable, CaseIterable {
        case global
        case panel
    }

    init(
        id: String,
        title: String,
        description: String? = nil,
        defaultCombination: KeyCombination,
        currentCombination: KeyCombination? = nil,
        scope: Scope = .global,
        isEditable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.defaultCombination = defaultCombination
        self.currentCombination = currentCombination ?? defaultCombination
        self.scope = scope
        self.isEditable = isEditable
    }

    /// Resets the shortcut to its default combination.
    mutating func resetToDefault() {
        currentCombination = defaultCombination
    }
}

/// A single key combination with optional modifier flags.
struct KeyCombination: Codable, Equatable, Hashable {
    var key: String
    var modifiers: ModifierFlags

    init(key: String, modifiers: ModifierFlags = ModifierFlags()) {
        self.key = key
        self.modifiers = modifiers
    }

    struct ModifierFlags: OptionSet, Codable, Equatable, Hashable {
        let rawValue: UInt

        static let command = ModifierFlags(rawValue: 1 << 0)
        static let option = ModifierFlags(rawValue: 1 << 1)
        static let control = ModifierFlags(rawValue: 1 << 2)
        static let shift = ModifierFlags(rawValue: 1 << 3)
        static let function = ModifierFlags(rawValue: 1 << 4)

        init(rawValue: UInt = 0) {
            self.rawValue = rawValue
        }
    }
}

extension KeyCombination {
    /// A human-readable representation, e.g. "⌘K" or "⌃⇧Return".
    var displayString: String {
        var result = ""
        if modifiers.contains(.command) { result += "⌘" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.function) { result += "fn" }
        result += key
        return result
    }

    /// A plain-text representation suitable for persistence or search.
    var canonicalString: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.function) { parts.append("fn") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

extension KeyboardShortcut.Scope: CustomStringConvertible {
    var description: String {
        switch self {
        case .global: return "Global"
        case .panel: return "Panel"
        }
    }
}