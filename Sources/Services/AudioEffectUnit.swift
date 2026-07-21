import Foundation
import AVFoundation
import CoreAudio

/// Identifies and parameterizes one AUv3 audio effect instance in a chain.
/// This is a pure data model (not a loaded AudioUnit) so it can be saved to
/// UserDefaults and reused across app launches.
struct AudioEffectUnit: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Display name from the component manager.
    var name: String
    /// Apple AudioUnit component description.
    var componentDescription: AudioComponentDescription
    /// User-tunable parameter values keyed by parameter address (AUParameterAddress).
    var parameters: [UInt64: Double]

    init(id: UUID = UUID(), name: String, componentDescription: AudioComponentDescription, parameters: [UInt64: Double] = [:]) {
        self.id = id
        self.name = name
        self.componentDescription = componentDescription
        self.parameters = parameters
    }

    var audioUnitDescription: AudioComponentDescription {
        componentDescription
    }
}

extension AudioComponentDescription: @retroactive Codable, @retroactive Hashable, @retroactive Equatable {
    public static func == (lhs: AudioComponentDescription, rhs: AudioComponentDescription) -> Bool {
        lhs.componentType == rhs.componentType
            && lhs.componentSubType == rhs.componentSubType
            && lhs.componentManufacturer == rhs.componentManufacturer
            && lhs.componentFlags == rhs.componentFlags
            && lhs.componentFlagsMask == rhs.componentFlagsMask
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(componentType)
        hasher.combine(componentSubType)
        hasher.combine(componentManufacturer)
        hasher.combine(componentFlags)
        hasher.combine(componentFlagsMask)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            componentType: try container.decode(OSType.self, forKey: .componentType),
            componentSubType: try container.decode(OSType.self, forKey: .componentSubType),
            componentManufacturer: try container.decode(OSType.self, forKey: .componentManufacturer),
            componentFlags: try container.decode(UInt32.self, forKey: .componentFlags),
            componentFlagsMask: try container.decode(UInt32.self, forKey: .componentFlagsMask)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(componentType, forKey: .componentType)
        try container.encode(componentSubType, forKey: .componentSubType)
        try container.encode(componentManufacturer, forKey: .componentManufacturer)
        try container.encode(componentFlags, forKey: .componentFlags)
        try container.encode(componentFlagsMask, forKey: .componentFlagsMask)
    }

    private enum CodingKeys: String, CodingKey {
        case componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask
    }
}

