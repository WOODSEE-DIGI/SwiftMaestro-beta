import Foundation
import GRDB

// MARK: - Import record

/// A single asset discovered inside an FCPXML document.
struct DAMFCPXMLImportRecord: Sendable {
    let path: String
    var keywords: Set<String> = []
    var flag: DAMFlag?
}

/// High-level result returned after applying FCPXML metadata to the catalog.
struct DAMFCPXMLImportSummary: Sendable {
    let matched: Int
    let updated: Int
    let keywords: Int
    let flags: Int
    let unmatched: Int
}

// MARK: - Errors

enum DAMFCPXMLImporterError: Error, Sendable {
    case parseFailed
}

// MARK: - Importer

/// Imports clip keywords and favorite/reject ratings from an FCPXML file.
///
/// FCPXML is the shared interchange format supported by both Final Cut Pro
/// (File → Export XML) and Premiere Pro (File → Export → Final Cut Pro XML).
/// The importer matches assets by absolute file path and merges keywords into
/// `userKeywords`; favorite/reject becomes `DAMFlag.pick`/`reject`.
@MainActor
final class DAMFCPXMLImporter: ObservableObject, Sendable {
    static let shared = DAMFCPXMLImporter()

    @Published var isImporting = false
    @Published var lastSummary: DAMFCPXMLImportSummary?
    @Published var lastError: String?

    private init() {}

    /// Reads the XML at `url` and applies any discovered metadata to the DAM catalog.
    nonisolated func importFile(at url: URL) async {
        await MainActor.run {
            self.isImporting = true
            self.lastError = nil
            self.lastSummary = nil
        }
        defer {
            Task { @MainActor in
                self.isImporting = false
            }
        }

        do {
            let records = try await parse(url: url)
            let summary = try await apply(records: records)
            await MainActor.run { self.lastSummary = summary }
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
    }

    // MARK: - Parsing

    /// Decompresses if needed ( Premiere `.prproj` is gzip; FCPXML is plain XML )
    /// and parses the XML on a background task.
    private nonisolated func parse(url: URL) async throws -> [DAMFCPXMLImportRecord] {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let delegate = FCPXMLParserDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse() else {
                throw parser.parserError ?? DAMFCPXMLImporterError.parseFailed
            }
            return delegate.records()
        }.value
    }

    // MARK: - Database application

    /// Merges parsed metadata into existing catalog rows keyed by path.
    private nonisolated func apply(records: [DAMFCPXMLImportRecord]) async throws -> DAMFCPXMLImportSummary {
        // Merge duplicate references to the same file.
        var map: [String: DAMFCPXMLImportRecord] = [:]
        for record in records {
            if var existing = map[record.path] {
                existing.keywords.formUnion(record.keywords)
                existing.flag = record.flag ?? existing.flag
                map[record.path] = existing
            } else {
                map[record.path] = record
            }
        }

        // The GRDB write closure is concurrent; capture an immutable snapshot.
        let snapshot = map

        return try await DAMDatabase.shared.dbQueue.write { db -> DAMFCPXMLImportSummary in
            var matched = 0
            var updated = 0
            var keywordCount = 0
            var flagCount = 0

            for (path, record) in snapshot {
                guard var asset = try DAMAsset.filter(DAMAsset.Columns.path == path).fetchOne(db) else {
                    continue
                }
                matched += 1
                var didChange = false

                if !record.keywords.isEmpty {
                    let existing = asset.userKeywords?
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter({ !$0.isEmpty }) ?? []
                    var combined = Set(existing)
                    let before = combined.count
                    combined.formUnion(record.keywords)
                    if combined.count != before {
                        asset.userKeywords = combined.sorted().joined(separator: ", ")
                        keywordCount += combined.count - before
                        didChange = true
                    }
                }

                if let flag = record.flag, asset.flag != flag {
                    asset.flag = flag
                    flagCount += 1
                    didChange = true
                }

                if didChange {
                    try asset.update(db)
                    updated += 1
                }
            }

            return DAMFCPXMLImportSummary(
                matched: matched,
                updated: updated,
                keywords: keywordCount,
                flags: flagCount,
                unmatched: snapshot.count - matched
            )
        }
    }
}

// MARK: - XML Parser Delegate

private final class FCPXMLParserDelegate: NSObject, XMLParserDelegate {
    private var assets: [String: String] = [:]
    private var keywordsByAsset: [String: Set<String>] = [:]
    private var flagByAsset: [String: DAMFlag] = [:]
    private var refStack: [String?] = []

    /// Builds import records from the collected resources and annotations.
    func records() -> [DAMFCPXMLImportRecord] {
        var records: [DAMFCPXMLImportRecord] = []
        for (id, src) in assets {
            guard let path = absolutePath(from: src) else { continue }
            records.append(DAMFCPXMLImportRecord(
                path: path,
                keywords: keywordsByAsset[id] ?? [],
                flag: flagByAsset[id]
            ))
        }
        return records
    }

    /// Converts a `file:///Volumes/.../clip.mov` FCPXML src to an absolute POSIX path.
    private func absolutePath(from src: String) -> String? {
        guard let url = URL(string: src) else { return nil }
        return url.path
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "asset", let id = attributeDict["id"], let src = attributeDict["src"] {
            assets[id] = src
        }

        refStack.append(attributeDict["ref"])

        guard let ref = attributeDict["ref"] ?? nearestRef() else { return }

        if elementName == "keyword", let name = attributeDict["name"] {
            keywordsByAsset[ref, default: []].insert(name)
        } else if elementName == "rating", let value = attributeDict["value"] {
            let flag: DAMFlag? = switch value {
            case "favorite": .pick
            case "reject": .reject
            default: nil
            }
            if let flag {
                flagByAsset[ref] = flag
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = refStack.popLast()
    }

    private func nearestRef() -> String? {
        refStack.lazy.compactMap({ $0 }).last
    }
}
