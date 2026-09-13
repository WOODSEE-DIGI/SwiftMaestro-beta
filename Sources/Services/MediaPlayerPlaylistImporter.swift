import Foundation

// MARK: - Playlist Import Errors

enum MediaPlayerPlaylistImportError: Error, LocalizedError {
    case unsupportedFormat
    case missingPlaylistFile
    case malformedXML
    case noPlayableTracks

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported playlist format. Use M3U, M3U8, PLS, or an iTunes/Music XML library."
        case .missingPlaylistFile:
            return "The playlist file could not be read."
        case .malformedXML:
            return "The iTunes/Music library XML could not be parsed."
        case .noPlayableTracks:
            return "No playable local tracks were found in the playlist."
        }
    }
}

// MARK: - Imported Playlist

struct ImportedPlaylist: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let tracks: [URL]
}

// MARK: - Playlist Importer

/// Imports media playlists into SwiftMaestro's Media Player queue.
///
/// Supports:
/// - M3U / M3U8 (standard plain-text playlists, including relative paths)
/// - PLS (Shoutcast/Winamp style INI playlists)
/// - iTunes / Apple Music library XML (playlists exported with
///   File → Library → Export Library)
///
/// DRM-protected Apple Music subscription tracks are skipped automatically,
/// because they cannot be played outside Apple's players.
enum MediaPlayerPlaylistImporter {

    /// Imports a single playlist file and returns the playable file URLs.
    static func importPlaylist(from url: URL) throws -> [URL] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m3u", "m3u8":
            return try parseM3U(url: url)
        case "pls":
            return try parsePLS(url: url)
        case "xml":
            let playlists = try playlists(fromXML: url)
            return playlists.first?.tracks ?? []
        default:
            throw MediaPlayerPlaylistImportError.unsupportedFormat
        }
    }

    /// Parses an iTunes / Apple Music library XML and returns every playlist
    /// that contains at least one playable local track.
    static func playlists(fromXML url: URL) throws -> [ImportedPlaylist] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaPlayerPlaylistImportError.missingPlaylistFile
        }

        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: PropertyListSerialization.ReadOptions(),
            format: nil
        )

        guard let root = plist as? [String: Any],
              let tracksDict = root["Tracks"] as? [String: [String: Any]],
              let playlistsArray = root["Playlists"] as? [[String: Any]] else {
            throw MediaPlayerPlaylistImportError.malformedXML
        }

        // Build a map of track ID -> playable local file URL.
        var trackURLs: [Int: URL] = [:]
        for (key, track) in tracksDict {
            guard let trackID = Int(key),
                  let location = track["Location"] as? String else { continue }

            // Skip DRM-protected subscription tracks (e.g. "Protected AAC audio file").
            if let kind = track["Kind"] as? String,
               kind.localizedCaseInsensitiveContains("protected") {
                continue
            }

            let fileURL: URL
            if let url = URL(string: location), url.isFileURL {
                fileURL = URL(fileURLWithPath: url.path)
            } else if location.hasPrefix("file://localhost/") {
                let path = String(location.dropFirst("file://localhost".count))
                fileURL = URL(fileURLWithPath: path)
            } else {
                continue
            }

            guard FileManager.default.fileExists(atPath: fileURL.path),
                  MediaPlayerFormat.canPlay(fileURL) else { continue }
            trackURLs[trackID] = fileURL
        }

        var imported: [ImportedPlaylist] = []
        for playlist in playlistsArray {
            guard let name = playlist["Name"] as? String,
                  let items = playlist["Playlist Items"] as? [[String: Any]] else { continue }

            let tracks = items.compactMap { item -> URL? in
                guard let trackID = item["Track ID"] as? Int else { return nil }
                return trackURLs[trackID]
            }

            if !tracks.isEmpty {
                imported.append(ImportedPlaylist(name: name, tracks: tracks))
            }
        }

        return imported
    }

    // MARK: - M3U / M3U8

    private static func parseM3U(url: URL) throws -> [URL] {
        let base = url.deletingLastPathComponent()
        let content = try String(contentsOf: url, encoding: .utf8)
        var result: [URL] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let fileURL = resolve(path: line, base: base),
                  FileManager.default.fileExists(atPath: fileURL.path),
                  MediaPlayerFormat.canPlay(fileURL) else { continue }
            result.append(fileURL)
        }

        return result
    }

    // MARK: - PLS

    private static func parsePLS(url: URL) throws -> [URL] {
        let base = url.deletingLastPathComponent()
        let content = try String(contentsOf: url, encoding: .utf8)
        var result: [URL] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("file") else { continue }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }

            let path = String(line[line.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let fileURL = resolve(path: path, base: base),
                  FileManager.default.fileExists(atPath: fileURL.path),
                  MediaPlayerFormat.canPlay(fileURL) else { continue }
            result.append(fileURL)
        }

        return result
    }

    // MARK: - Path resolution

    /// Resolves a path string from a playlist into a file URL.
    /// Handles `file://` URLs, absolute paths, and paths relative to the
    /// playlist file's directory.
    private static func resolve(path: String, base: URL) -> URL? {
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            return URL(fileURLWithPath: url.path)
        }
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path)
        }
        return base.appendingPathComponent(path).standardizedFileURL
    }
}
