import Foundation

// MARK: - Story Game Project
//
// Canonical on-disk model for a SwiftMaestro Game Studio project. All IDs
// are string slugs so they survive serialization and can be referenced across
// scenes, characters, and locations without UUID churn.

struct StoryGameProject: Codable, Identifiable, Sendable {
    var id: UUID
    var metadata: StoryMetadata
    var statDefinitions: [String: StatDefinition]
    var characters: [String: StoryCharacter]
    var locations: [String: StoryLocation]
    var scenes: [StoryScene]
    var mapImageFilename: String?

    init(
        id: UUID,
        metadata: StoryMetadata,
        statDefinitions: [String: StatDefinition],
        characters: [String: StoryCharacter],
        locations: [String: StoryLocation],
        scenes: [StoryScene],
        mapImageFilename: String? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.statDefinitions = statDefinitions
        self.characters = characters
        self.locations = locations
        self.scenes = scenes
        self.mapImageFilename = mapImageFilename
    }
}

struct StoryMetadata: Codable, Sendable {
    var title: String
    var subtitle: String?
    var version: Int

    init(title: String, subtitle: String? = nil, version: Int = 1) {
        self.title = title
        self.subtitle = subtitle
        self.version = version
    }
}

struct StatDefinition: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var defaultValue: Int
    var min: Int
    var max: Int
    var isDanger: Bool

    init(
        id: String,
        name: String,
        defaultValue: Int,
        min: Int,
        max: Int,
        isDanger: Bool
    ) {
        self.id = id
        self.name = name
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.isDanger = isDanger
    }
}

struct StoryCharacter: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var role: String
    var aliases: [String]
    var bio: String
    var motivation: String
    var notes: String
    var keyQuotes: [String]
    var icon: String
    var portraitFilename: String?

    init(
        id: String,
        name: String,
        role: String = "",
        aliases: [String] = [],
        bio: String = "",
        motivation: String = "",
        notes: String = "",
        keyQuotes: [String] = [],
        icon: String = "✦",
        portraitFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.aliases = aliases
        self.bio = bio
        self.motivation = motivation
        self.notes = notes
        self.keyQuotes = keyQuotes
        self.icon = icon
        self.portraitFilename = portraitFilename
    }
}

struct StoryLocation: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var mapPosition: MapPosition?
    var notes: String

    init(
        id: String,
        name: String,
        description: String = "",
        mapPosition: MapPosition? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.mapPosition = mapPosition
        self.notes = notes
    }
}

struct MapPosition: Codable, Sendable {
    var x: Double
    var y: Double
}

struct StoryScene: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var date: String?
    var displayDate: String?
    var locationID: String?
    var primaryCharacterID: String?
    var narrative: String
    var sceneType: String
    var choices: [StoryChoice]
    var symbols: [String]
    var characterIDs: [String]
    var notes: String
    var sourceEventIDs: [String]

    init(
        id: String,
        title: String,
        date: String? = nil,
        displayDate: String? = nil,
        locationID: String? = nil,
        primaryCharacterID: String? = nil,
        narrative: String = "",
        sceneType: String = "event",
        choices: [StoryChoice] = [],
        symbols: [String] = [],
        characterIDs: [String] = [],
        notes: String = "",
        sourceEventIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.displayDate = displayDate
        self.locationID = locationID
        self.primaryCharacterID = primaryCharacterID
        self.narrative = narrative
        self.sceneType = sceneType
        self.choices = choices
        self.symbols = symbols
        self.characterIDs = characterIDs
        self.notes = notes
        self.sourceEventIDs = sourceEventIDs
    }
}

struct StoryChoice: Codable, Identifiable, Sendable {
    var id: String
    var text: String
    var targetSceneID: String?
    var effects: [String: Int]
    var consequence: String
    var isHistorical: Bool

    init(
        id: String,
        text: String,
        targetSceneID: String? = nil,
        effects: [String: Int] = [:],
        consequence: String = "",
        isHistorical: Bool = false
    ) {
        self.id = id
        self.text = text
        self.targetSceneID = targetSceneID
        self.effects = effects
        self.consequence = consequence
        self.isHistorical = isHistorical
    }
}
