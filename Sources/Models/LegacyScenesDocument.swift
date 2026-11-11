import Foundation

// MARK: - Legacy Scenes JSON
//
// Decodable mirror of the scenes.json format produced by the current
// Sans Souci Divorce game pipeline. Used only for one-time import into the
// canonical StoryGameProject format.

struct LegacyScenesDocument: Codable {
    var metadata: LegacyMetadata?
    var characters: [String: LegacyCharacter]?
    var scenes: [LegacyScene]?
}

struct LegacyMetadata: Codable {
    var title: String?
    var subtitle: String?
    var totalScenes: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case totalScenes = "total_scenes"
    }
}

struct LegacyCharacter: Codable {
    var name: String?
    var role: String?
    var description: String?
    var icon: String?
    var firstScene: String?
    var portrait: String?

    enum CodingKeys: String, CodingKey {
        case name
        case role
        case description
        case icon
        case firstScene = "first_scene"
        case portrait
    }
}

struct LegacyScene: Codable {
    var id: String
    var date: String?
    var displayDate: String?
    var title: String?
    var narrative: String?
    var type: String?
    var choices: [LegacyChoice]?
    var chosenChoice: String?
    var consequence: String?
    var statChanges: [String: Int]?
    var symbols: [String]?
    var characters: [String]?
    var character: String?
    var location: String?
    var sourceEventIDs: [String]?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case displayDate = "display_date"
        case title
        case narrative
        case type
        case choices
        case chosenChoice = "chosen_choice"
        case consequence
        case statChanges = "stat_changes"
        case symbols
        case characters
        case character
        case location
        case sourceEventIDs = "source_event_ids"
        case notes
    }
}

struct LegacyChoice: Codable {
    var id: String?
    var text: String?
    var historical: Bool?
}
