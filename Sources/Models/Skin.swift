import SwiftUI

/// A named color theme ("skin") that can be saved, imported, and applied to the
/// app. Each property is an optional 8-digit RRGGBBAA hex string. Missing values
/// fall back to the system defaults, so a skin can be as minimal or complete as
/// the user wants.
struct Skin: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var description: String?
    var isBuiltIn: Bool = false
    var appearance: ThemeStore.Appearance = .system
    var accent: String?
    var userBubble: String?
    var userBubbleText: String?
    var chatBackground: String?
    var chatText: String?
    var sidebarBackground: String?
    var sidebarText: String?
    var plansPanel: String?
    var plansText: String?
    var tasksPanel: String?
    var tasksText: String?
    var background: String?
    var secondaryBackground: String?
    var panelAccents: [String: String]?

    /// A stable, URL-safe identifier derived from the name if none is supplied.
    init(
        id: String? = nil,
        name: String,
        description: String? = nil,
        isBuiltIn: Bool = false,
        appearance: ThemeStore.Appearance = .system,
        accent: String? = nil,
        userBubble: String? = nil,
        userBubbleText: String? = nil,
        chatBackground: String? = nil,
        chatText: String? = nil,
        sidebarBackground: String? = nil,
        sidebarText: String? = nil,
        plansPanel: String? = nil,
        plansText: String? = nil,
        tasksPanel: String? = nil,
        tasksText: String? = nil,
        background: String? = nil,
        secondaryBackground: String? = nil,
        panelAccents: [String: String]? = nil
    ) {
        self.id = id ?? name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.appearance = appearance
        self.accent = accent
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.chatBackground = chatBackground
        self.chatText = chatText
        self.sidebarBackground = sidebarBackground
        self.sidebarText = sidebarText
        self.plansPanel = plansPanel
        self.plansText = plansText
        self.tasksPanel = tasksPanel
        self.tasksText = tasksText
        self.background = background
        self.secondaryBackground = secondaryBackground
        self.panelAccents = panelAccents
    }

    /// JSON representation, pretty-printed so exported files are human-editable.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func from(jsonData: Data) throws -> Skin {
        try JSONDecoder().decode(Skin.self, from: jsonData)
    }
}

extension Skin {
    /// The default system look — no overrides at all.
    static var `default`: Skin {
        Skin(id: "default", name: "System Default", description: "Follows the system accent and window backgrounds.", isBuiltIn: true)
    }
}
