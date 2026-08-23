import AppKit
import Foundation
import SwiftTerm

// MARK: - Terminal Settings
//
// iTerm2-style display preferences for the Live Terminal: font, size, and
// colors, with named presets. Persisted as JSON in Application Support so
// every shell tab (and every future panel showing a terminal) renders the
// same environment. Applied live — changing a value re-themes open shells
// without restarting their processes.

@Observable
final class TerminalSettings: @unchecked Sendable {
    static let shared = TerminalSettings()

    var fontName: String { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var foregroundHex: String { didSet { save() } }
    var backgroundHex: String { didSet { save() } }
    var cursorHex: String { didSet { save() } }
    /// Scrollback buffer lines per terminal (SwiftTerm changeScrollback).
    var scrollbackLines: Int { didSet { save() } }
    /// 16-color ANSI palette preset name; "Default" leaves SwiftTerm's
    /// built-in palette untouched.
    var paletteName: String { didSet { save() } }

    private init() {
        let defaults = Self.presetDefaultDark
        fontName = defaults.fontName
        fontSize = defaults.fontSize
        foregroundHex = defaults.foregroundHex
        backgroundHex = defaults.backgroundHex
        cursorHex = defaults.cursorHex
        scrollbackLines = 10_000
        paletteName = "Default"
        load()
    }

    // MARK: - Resolved values

    var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var foregroundColor: NSColor { Self.nsColor(fromHex: foregroundHex) ?? NSColor(white: 0.92, alpha: 1) }
    var backgroundColor: NSColor { Self.nsColor(fromHex: backgroundHex) ?? NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) }
    var cursorColor: NSColor { Self.nsColor(fromHex: cursorHex) ?? NSColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1) }

    // MARK: - Presets

    struct Preset: Sendable {
        let name: String
        let fontName: String
        let fontSize: Double
        let foregroundHex: String
        let backgroundHex: String
        let cursorHex: String
    }

    static var presetDefaultDark: Preset {
        Preset(name: "Default Dark",
               fontName: "Menlo-Regular", fontSize: 12,
               foregroundHex: "EBEBEBFF", backgroundHex: "1C1C1FFF",
               cursorHex: "33CC73FF")
    }

    static var presets: [Preset] {
        [
            presetDefaultDark,
            Preset(name: "btop Phosphor",
                   fontName: "Menlo-Regular", fontSize: 12,
                   foregroundHex: "33FF59FF", backgroundHex: "0A0F0AFF",
                   cursorHex: "33FF59FF"),
            Preset(name: "Solarized Dark",
                   fontName: "Menlo-Regular", fontSize: 12,
                   foregroundHex: "839496FF", backgroundHex: "002B36FF",
                   cursorHex: "93A1A1FF"),
            Preset(name: "Solarized Light",
                   fontName: "Menlo-Regular", fontSize: 12,
                   foregroundHex: "657B83FF", backgroundHex: "FDF6E3FF",
                   cursorHex: "586E75FF"),
            Preset(name: "Classic Green (Apple II)",
                   fontName: "Menlo-Regular", fontSize: 13,
                   foregroundHex: "33DD33FF", backgroundHex: "000000FF",
                   cursorHex: "33DD33FF"),
            Preset(name: "Amber CRT",
                   fontName: "Menlo-Regular", fontSize: 13,
                   foregroundHex: "FFB000FF", backgroundHex: "0F0800FF",
                   cursorHex: "FFB000FF"),
        ]
    }

    func apply(_ preset: Preset) {
        fontName = preset.fontName
        fontSize = preset.fontSize
        foregroundHex = preset.foregroundHex
        backgroundHex = preset.backgroundHex
        cursorHex = preset.cursorHex
    }

    /// Monospace fonts available on this Mac, for the picker.
    static var availableMonospaceFonts: [String] {
        let all = NSFontManager.shared.availableFontFamilies
        // Curated: families that are reliably monospaced on macOS.
        let known = ["Menlo", "SF Mono", "Monaco", "Courier New", "Andale Mono",
                     "JetBrains Mono", "Fira Code", "Hack", "IBM Plex Mono",
                     "Source Code Pro", "Cascadia Code", "Cascadia Mono"]
        return known.filter { all.contains($0) }
    }

    /// Resolve a family name to a usable PostScript name for NSFont(name:).
    static func postScriptName(forFamily family: String, size: Double) -> String {
        if let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
           let first = members.first,
           let psName = first[0] as? String {
            return psName
        }
        return family
    }

    // MARK: - ANSI palettes
    // 16 entries each: 0-7 normal (black red green yellow blue magenta cyan
    // white), 8-15 bright. "Default" is nil — SwiftTerm's stock palette.

    static let palettes: [(name: String, colors: [String]?)] = [
        ("Default", nil),
        ("btop Phosphor", [
            "0A0F0A", "FF4D40", "33FF59", "FFB000", "3FBFBF", "4DA6FF", "B85CFF", "CFFFD8",
            "1E3320", "FF6B5E", "6BFF8A", "FFD24D", "6FD9D9", "7DBCFF", "D29BFF", "FFFFFF",
        ]),
        ("Solarized Dark", [
            "073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
            "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3",
        ]),
        ("Solarized Light", [
            "EEE8D5", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "073642",
            "FDF6E3", "CB4B16", "93A1A1", "839496", "657B83", "6C71C4", "586E75", "002B36",
        ]),
        ("Amber CRT", [
            "0F0800", "FF5A1F", "FFB000", "FFE08A", "FF8C00", "D2691E", "FFC04D", "FFEECC",
            "332000", "FF7A3D", "FFC933", "FFEBB0", "FFA626", "E0852A", "FFD280", "FFF7E6",
        ]),
    ]

    /// The active palette as SwiftTerm Colors, or nil for the stock palette.
    var paletteColors: [SwiftTerm.Color]? {
        guard let entry = Self.palettes.first(where: { $0.name == paletteName }),
              let hexes = entry.colors else { return nil }
        return hexes.compactMap { hex in
            guard let ns = Self.nsColor(fromHex: hex) else { return nil }
            guard let srgb = ns.usingColorSpace(.sRGB) else { return nil }
            return SwiftTerm.Color(
                red: UInt16(srgb.redComponent * 65535),
                green: UInt16(srgb.greenComponent * 65535),
                blue: UInt16(srgb.blueComponent * 65535)
            )
        }
    }

    /// Scrollback choices offered in the Display popover.
    static let scrollbackChoices: [Int] = [1_000, 5_000, 10_000, 50_000, 100_000]

    // MARK: - Hex helpers

    static func nsColor(fromHex hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 6 { value += "FF" }
        guard value.count == 8, let raw = UInt32(value, radix: 16) else { return nil }
        let r = CGFloat((raw >> 24) & 0xFF) / 255
        let g = CGFloat((raw >> 16) & 0xFF) / 255
        let b = CGFloat((raw >> 8) & 0xFF) / 255
        let a = CGFloat(raw & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func hex(from color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "FFFFFFFF" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var fontName: String
        var fontSize: Double
        var foregroundHex: String
        var backgroundHex: String
        var cursorHex: String
        var scrollbackLines: Int?
        var paletteName: String?
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminal-settings.json")
    }

    private func save() {
        let p = Persisted(fontName: fontName, fontSize: fontSize,
                          foregroundHex: foregroundHex, backgroundHex: backgroundHex,
                          cursorHex: cursorHex, scrollbackLines: scrollbackLines,
                          paletteName: paletteName)
        try? JSONEncoder().encode(p).write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        fontName = p.fontName
        fontSize = p.fontSize
        foregroundHex = p.foregroundHex
        backgroundHex = p.backgroundHex
        cursorHex = p.cursorHex
        if let scrollbackLines = p.scrollbackLines { self.scrollbackLines = scrollbackLines }
        if let paletteName = p.paletteName { self.paletteName = paletteName }
    }
}
