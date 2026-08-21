import Foundation

// MARK: - Clip Templates
//
// Obsidian Web Clipper-style templates for web clips. A template defines:
// - which URLs it auto-matches (e.g. "youtube.com")
// - the note name format ("{{title}}")
// - the vault folder ("Clippings")
// - typed properties (rendered to YAML frontmatter in Notes, typed cells in MaestroDB)
// - the note body format
//
// Templates use {{variable}} interpolation with pipe filters:
//   {{title}}                          — simple variable
//   {{published|date:"yyyy-MM-dd"}}    — date reformat
//   {{author|default:"Unknown"}}       — fallback
//   {{tags|join:", "}}                 — array join
//   {{meta:property:og:title}}         — meta tag lookup
//   {{schema:@Article:headline}}       — schema.org JSON-LD lookup

struct ClipTemplate: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Substring match against the page URL/host (case-insensitive).
    /// Empty = never auto-matches (manual pick only).
    var urlPatterns: [String]
    /// Folder inside the Notes vault, e.g. "Clippings" or "Research/AI".
    var folder: String
    /// Note filename format, e.g. "{{title}}".
    var noteNameFormat: String
    var properties: [ClipProperty]
    /// Markdown body. {{content}} is the cleaned article markdown.
    var bodyFormat: String

    // MARK: Destinations (per-template)

    /// Write the rendered note into the Notes vault (in `folder`).
    var saveToNotes: Bool
    /// Write a typed row into MaestroDB.
    var saveToMaestroDB: Bool
    /// MaestroDB base name for this template's clips (created if missing).
    var maestroBase: String
    /// MaestroDB table name inside that base (created if missing).
    var maestroTable: String
    /// Download the page's images into an assets folder next to the note and
    /// rewrite links to local paths (Wayback-style snapshot). Also saves the
    /// full page HTML alongside the note.
    var downloadAssets: Bool
    /// Write capture-metadata.json beside the clip: universal + local
    /// timestamps, HTTP transport (status, final URL, headers), TLS cert, and
    /// the domain's RDAP record (registrar, registration/expiry dates,
    /// nameservers). For investigative provenance — opt-in per template.
    var captureForensics: Bool

    init(id: UUID = UUID(), name: String, urlPatterns: [String] = [],
         folder: String = "Clippings", noteNameFormat: String = "{{title}}",
         properties: [ClipProperty], bodyFormat: String,
         saveToNotes: Bool = true, saveToMaestroDB: Bool = true,
         maestroBase: String = "Web Clips", maestroTable: String = "Clips",
         downloadAssets: Bool = true, captureForensics: Bool = false) {
        self.id = id
        self.name = name
        self.urlPatterns = urlPatterns
        self.folder = folder
        self.noteNameFormat = noteNameFormat
        self.properties = properties
        self.bodyFormat = bodyFormat
        self.saveToNotes = saveToNotes
        self.saveToMaestroDB = saveToMaestroDB
        self.maestroBase = maestroBase
        self.maestroTable = maestroTable
        self.downloadAssets = downloadAssets
        self.captureForensics = captureForensics
    }

    /// Custom decoder: templates saved before destinations existed decode
    /// with the legacy behavior (both destinations, Web Clips base).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        urlPatterns = (try? c.decode([String].self, forKey: .urlPatterns)) ?? []
        folder = (try? c.decode(String.self, forKey: .folder)) ?? "Clippings"
        noteNameFormat = (try? c.decode(String.self, forKey: .noteNameFormat)) ?? "{{title}}"
        properties = (try? c.decode([ClipProperty].self, forKey: .properties)) ?? []
        bodyFormat = (try? c.decode(String.self, forKey: .bodyFormat)) ?? "{{content}}\n"
        saveToNotes = (try? c.decode(Bool.self, forKey: .saveToNotes)) ?? true
        saveToMaestroDB = (try? c.decode(Bool.self, forKey: .saveToMaestroDB)) ?? true
        maestroBase = (try? c.decode(String.self, forKey: .maestroBase)) ?? "Web Clips"
        maestroTable = (try? c.decode(String.self, forKey: .maestroTable)) ?? "Clips"
        downloadAssets = (try? c.decode(Bool.self, forKey: .downloadAssets)) ?? true
        captureForensics = (try? c.decode(Bool.self, forKey: .captureForensics)) ?? false
    }

    /// Case-insensitive substring match against the full URL.
    func matches(url: String) -> Bool {
        let needle = url.lowercased()
        return urlPatterns.contains { !$0.isEmpty && needle.contains($0.lowercased()) }
    }
}

struct ClipProperty: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var valueTemplate: String
    var type: ClipPropertyType

    init(id: UUID = UUID(), name: String, valueTemplate: String, type: ClipPropertyType = .text) {
        self.id = id
        self.name = name
        self.valueTemplate = valueTemplate
        self.type = type
    }
}

enum ClipPropertyType: String, Codable, CaseIterable, Sendable {
    case text, multitext, number, checkbox, date, datetime

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .multitext: return "List"
        case .number: return "Number"
        case .checkbox: return "Checkbox"
        case .date: return "Date"
        case .datetime: return "Date & time"
        }
    }
}

// MARK: - Built-in templates

extension ClipTemplate {
    static let defaultTemplate = ClipTemplate(
        name: "Default",
        properties: [
            ClipProperty(name: "title", valueTemplate: "{{title}}"),
            ClipProperty(name: "source", valueTemplate: "{{url}}"),
            ClipProperty(name: "author", valueTemplate: "{{author}}"),
            ClipProperty(name: "published", valueTemplate: "{{published|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "created", valueTemplate: "{{date|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "description", valueTemplate: "{{description}}"),
            ClipProperty(name: "tags", valueTemplate: "clippings", type: .multitext),
        ],
        bodyFormat: "{{content}}\n"
    )

    static let researchTemplate = ClipTemplate(
        name: "Research",
        folder: "Clippings/Research",
        properties: [
            ClipProperty(name: "title", valueTemplate: "{{title}}"),
            ClipProperty(name: "source", valueTemplate: "{{url}}"),
            ClipProperty(name: "domain", valueTemplate: "{{domain}}"),
            ClipProperty(name: "author", valueTemplate: "{{author}}"),
            ClipProperty(name: "published", valueTemplate: "{{published|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "created", valueTemplate: "{{date|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "site", valueTemplate: "{{site}}"),
            ClipProperty(name: "words", valueTemplate: "{{words}}", type: .number),
            ClipProperty(name: "description", valueTemplate: "{{description}}"),
            ClipProperty(name: "image", valueTemplate: "{{image}}"),
            ClipProperty(name: "tags", valueTemplate: "clippings, research", type: .multitext),
        ],
        bodyFormat: """
        ## Summary
        {{description}}

        ## Content
        {{content}}

        ---
        [Original]({{url}})
        """
    )

    static let youtubeTemplate = ClipTemplate(
        name: "YouTube",
        urlPatterns: ["youtube.com", "youtu.be"],
        folder: "Clippings/YouTube",
        noteNameFormat: "{{schema:@VideoObject:name|default:{{title}}}}",
        properties: [
            ClipProperty(name: "title", valueTemplate: "{{schema:@VideoObject:name|default:{{title}}}}"),
            ClipProperty(name: "source", valueTemplate: "{{url}}"),
            ClipProperty(name: "channel", valueTemplate: "{{schema:@VideoObject:author|default:{{author}}}}"),
            ClipProperty(name: "published", valueTemplate: "{{schema:@VideoObject:uploadDate|default:{{published}}|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "created", valueTemplate: "{{date|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "thumbnail", valueTemplate: "{{schema:@VideoObject:thumbnailUrl|default:{{image}}}}"),
            ClipProperty(name: "tags", valueTemplate: "clippings, YouTube", type: .multitext),
        ],
        bodyFormat: """
        [![]({{image}})]({{url}})

        {{content}}
        """
    )

    /// Investigative template: full asset snapshot + forensic metadata file
    /// (timestamps, transport, TLS, RDAP domain record).
    static let forensicsTemplate = ClipTemplate(
        name: "Forensics",
        folder: "Clippings/Forensics",
        properties: [
            ClipProperty(name: "title", valueTemplate: "{{title}}"),
            ClipProperty(name: "source", valueTemplate: "{{url}}"),
            ClipProperty(name: "domain", valueTemplate: "{{domain}}"),
            ClipProperty(name: "author", valueTemplate: "{{author}}"),
            ClipProperty(name: "published", valueTemplate: "{{published|date:\"yyyy-MM-dd\"}}", type: .date),
            ClipProperty(name: "captured_utc", valueTemplate: "{{date}}", type: .datetime),
            ClipProperty(name: "captured_local", valueTemplate: "{{date|date:\"yyyy-MM-dd HH:mm\"}}"),
            ClipProperty(name: "description", valueTemplate: "{{description}}"),
            ClipProperty(name: "tags", valueTemplate: "clippings, forensics", type: .multitext),
        ],
        bodyFormat: """
        # {{title}}

        > Captured {{date|date:"yyyy-MM-dd 'at' HH:mm"}} — forensic metadata in `capture-metadata.json` beside this note.

        {{content}}

        ---
        [Original]({{url}})
        """,
        downloadAssets: true,
        captureForensics: true
    )

    static var builtIns: [ClipTemplate] { [defaultTemplate, researchTemplate, youtubeTemplate, forensicsTemplate] }
}
