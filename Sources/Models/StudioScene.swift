import Foundation
import SwiftUI

/// A source that can be placed as a layer in a `StudioScene`.
enum SceneSource: Codable, Hashable, Sendable {
    /// A camera from the tethering/camera service.
    case camera(sourceID: String)
    /// An NDI source discovered by `NDIBrowserService`.
    case ndi(endpoint: String)
    /// A still image on disk.
    case image(url: String)
    /// Text overlay with content and styling.
    case text(
        content: String,
        fontSize: Double,
        foregroundColor: SceneColor,
        backgroundColor: SceneColor?
    )
    /// Solid color fill.
    case color(SceneColor)
    /// Screen or window capture. The descriptor is a placeholder for future expansion.
    case screen(descriptor: String)
}

/// A portable color representation for scene layers.
struct SceneColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    static let white = SceneColor(red: 1, green: 1, blue: 1, opacity: 1)
    static let black = SceneColor(red: 0, green: 0, blue: 0, opacity: 1)
    static let red = SceneColor(red: 1, green: 0, blue: 0, opacity: 1)
    static let green = SceneColor(red: 0, green: 1, blue: 0, opacity: 1)
    static let blue = SceneColor(red: 0, green: 0, blue: 1, opacity: 1)
    static let clear = SceneColor(red: 0, green: 0, blue: 0, opacity: 0)

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    init(_ color: Color) {
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.displayP3) ?? nsColor.usingColorSpace(.sRGB) else {
            self.red = 1
            self.green = 1
            self.blue = 1
            self.opacity = 1
            return
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
    }
}

/// A normalized crop rectangle within the source content of a layer.
/// Values are in the unit coordinate space of the source (0...1).
struct SceneLayerCrop: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = SceneLayerCrop(x: 0, y: 0, width: 1, height: 1)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A single layer inside a scene. Layers are rendered in z-index order.
struct SceneLayer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var source: SceneSource
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var zIndex: Int
    var isVisible: Bool
    var opacity: Double
    /// Crop region within the source content, normalized to 0...1.
    var crop: SceneLayerCrop

    init(
        id: UUID = UUID(),
        name: String,
        source: SceneSource,
        x: Double = 0,
        y: Double = 0,
        width: Double = 320,
        height: Double = 180,
        zIndex: Int = 0,
        isVisible: Bool = true,
        opacity: Double = 1,
        crop: SceneLayerCrop = .full
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.isVisible = isVisible
        self.opacity = opacity
        self.crop = crop
    }

    enum CodingKeys: String, CodingKey {
        case id, name, source, x, y, width, height, zIndex, isVisible, opacity, crop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.source = try container.decode(SceneSource.self, forKey: .source)
        self.x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        self.y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        self.width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 320
        self.height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 180
        self.zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        self.crop = try container.decodeIfPresent(SceneLayerCrop.self, forKey: .crop) ?? .full
    }
}

/// A scene is a multi-layer canvas that can be previewed and routed to a broadcast
/// or mixer output.
struct StudioScene: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var width: Int
    var height: Int
    var layers: [SceneLayer]
    /// If set, the scene is rendered to this broadcast destination when active.
    var outputBroadcastSessionID: UUID?
    /// If set, the scene is rendered to this mixer route when active.
    var outputMixerRouteID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        width: Int = 1920,
        height: Int = 1080,
        layers: [SceneLayer] = [],
        outputBroadcastSessionID: UUID? = nil,
        outputMixerRouteID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.layers = layers
        self.outputBroadcastSessionID = outputBroadcastSessionID
        self.outputMixerRouteID = outputMixerRouteID
    }

    static func `default`() -> StudioScene {
        StudioScene(name: "Main", layers: [])
    }
}

enum SceneOutputTarget: Hashable, Sendable {
    case broadcast(UUID)
    case mixerRoute(UUID)
    case none
}

extension StudioScene {
    var outputTarget: SceneOutputTarget {
        if let id = outputBroadcastSessionID { return .broadcast(id) }
        if let id = outputMixerRouteID { return .mixerRoute(id) }
        return .none
    }
}
