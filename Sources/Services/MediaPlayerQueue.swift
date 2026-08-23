import Foundation
import SwiftUI

// MARK: - Repeat Mode

enum MediaPlayerRepeatMode: String, CaseIterable, Codable, Sendable {
    case off, one, all
}

// MARK: - Media Player Queue
//
// Playlist / queue management for the media player. Tracks a list of
// media items, the current index, and provides navigation. Persists
// the last-used playlist to disk so it survives relaunches.

@Observable
@MainActor
final class MediaPlayerQueue {
    static let shared = MediaPlayerQueue()

    /// A single entry in the playlist.
    struct Entry: Identifiable, Hashable, Sendable {
        let id: UUID
        let url: URL
        var title: String
        var artist: String?
        var duration: Double?
        var isPlaying: Bool = false

        init(url: URL, title: String? = nil, artist: String? = nil, duration: Double? = nil) {
            self.id = UUID()
            self.url = url
            self.title = title ?? url.deletingPathExtension().lastPathComponent
            self.artist = artist
            self.duration = duration
        }
    }

    /// The playlist entries.
    var entries: [Entry] = []

    /// Index of the currently playing entry, or nil.
    var currentIndex: Int?

    /// Whether shuffle is enabled.
    var shuffleEnabled = false

    /// Repeat mode: off, one, all.
    var repeatMode: MediaPlayerRepeatMode = .off

    /// The currently playing entry, if any.
    var currentEntry: Entry? {
        guard let idx = currentIndex, idx < entries.count else { return nil }
        return entries[idx]
    }

    /// Number of entries.
    var count: Int { entries.count }

    /// Whether the queue is empty.
    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Persistence

    private static let savePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/data/media-player")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }()

    // MARK: - Queue Operations

    /// Add a file to the end of the queue.
    func append(url: URL) {
        let entry = Entry(url: url)
        entries.append(entry)
        save()
    }

    /// Add multiple files to the end of the queue.
    func append(contentsOf urls: [URL]) {
        for url in urls {
            entries.append(Entry(url: url))
        }
        save()
    }

    /// Insert a file after the current index.
    func insertNext(url: URL) {
        let entry = Entry(url: url)
        let insertIdx = (currentIndex ?? -1) + 1
        entries.insert(entry, at: min(insertIdx, entries.count))
        save()
    }

    /// Remove an entry by its identity.
    func remove(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: idx)
        adjustCurrentIndexAfterRemoval(removedIndex: idx)
        save()
    }

    /// Remove entries at specific index set.
    func remove(at offsets: IndexSet) {
        let sorted = offsets.sorted().reversed()
        for idx in sorted {
            entries.remove(at: idx)
        }
        adjustCurrentIndexAfterRemoval(removedIndex: offsets.first ?? 0)
        save()
    }

    /// Move an entry from one position to another (for drag reorder).
    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        adjustCurrentIndexAfterRemoval(removedIndex: source.first ?? 0)
        save()
    }

    /// Clear the entire queue.
    func clear() {
        entries.removeAll()
        currentIndex = nil
        save()
    }

    /// Update metadata for an entry (e.g., after loading duration).
    func updateEntry(id: UUID, title: String? = nil, artist: String? = nil, duration: Double? = nil) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if let title { entries[idx].title = title }
        if let artist { entries[idx].artist = artist }
        if let duration { entries[idx].duration = duration }
    }

    // MARK: - Navigation

    /// Select and load the next track. Returns the URL to load, or nil.
    @discardableResult
    func next() -> URL? {
        guard !entries.isEmpty else { return nil }

        switch repeatMode {
        case .one:
            // Replay current.
            return currentEntry?.url

        case .all:
            if shuffleEnabled {
                let nextIdx = Int.random(in: 0..<entries.count)
                currentIndex = nextIdx
            } else {
                let nextIdx = (currentIndex ?? -1) + 1
                if nextIdx >= entries.count {
                    currentIndex = 0
                } else {
                    currentIndex = nextIdx
                }
            }

        case .off:
            if shuffleEnabled {
                let nextIdx = Int.random(in: 0..<entries.count)
                currentIndex = nextIdx
            } else {
                let nextIdx = (currentIndex ?? -1) + 1
                guard nextIdx < entries.count else { return nil }
                currentIndex = nextIdx
            }
        }

        save()
        return currentEntry?.url
    }

    /// Select and load the previous track. Returns the URL to load, or nil.
    @discardableResult
    func previous() -> URL? {
        guard !entries.isEmpty else { return nil }

        if shuffleEnabled {
            let prevIdx = Int.random(in: 0..<entries.count)
            currentIndex = prevIdx
        } else {
            let prevIdx = (currentIndex ?? 1) - 1
            currentIndex = max(0, prevIdx)
        }

        save()
        return currentEntry?.url
    }

    /// Start playing from a specific index.
    func playIndex(_ idx: Int) -> URL? {
        guard idx >= 0, idx < entries.count else { return nil }
        currentIndex = idx
        save()
        return entries[idx].url
    }

    /// Add files and start playing the first one.
    func playFiles(_ urls: [URL]) -> URL? {
        clear()
        append(contentsOf: urls)
        currentIndex = 0
        save()
        return entries.first?.url
    }

    // MARK: - Shuffle Helpers

    func toggleShuffle() {
        shuffleEnabled.toggle()
        save()
    }

    func toggleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        save()
    }

    // MARK: - Private

    private func adjustCurrentIndexAfterRemoval(removedIndex: Int) {
        guard let cur = currentIndex else { return }
        if entries.isEmpty {
            currentIndex = nil
        } else if cur > removedIndex {
            currentIndex = cur - 1
        } else if cur >= entries.count {
            currentIndex = entries.count - 1
        }
    }

    // MARK: - Persistence

    func save() {
        let data = QueueData(
            entries: entries.map { .init(url: $0.url, title: $0.title, artist: $0.artist, duration: $0.duration) },
            currentIndex: currentIndex,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: Self.savePath, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.savePath),
              let decoded = try? JSONDecoder().decode(QueueData.self, from: data) else { return }
        entries = decoded.entries.map { Entry(url: $0.url, title: $0.title, artist: $0.artist, duration: $0.duration) }
        currentIndex = decoded.currentIndex
        shuffleEnabled = decoded.shuffleEnabled
        repeatMode = decoded.repeatMode
    }

    private struct QueueData: Codable {
        struct EntryData: Codable {
            let url: URL
            let title: String
            let artist: String?
            let duration: Double?
        }
        let entries: [EntryData]
        let currentIndex: Int?
        let shuffleEnabled: Bool
        let repeatMode: MediaPlayerRepeatMode
    }
}

// MARK: - Supported Formats

/// File types the media player can open.
enum MediaPlayerFormat {
    /// Formats AVKit on macOS actually decodes (hardware-accelerated where
    /// available). Anything NOT in this set routes through the FFmpeg
    /// fallback (remux or transcode to H.264/AAC MP4, or AAC M4A for audio).
    static let nativeExtensions: Set<String> = [
        // Video (QuickTime-family containers + codecs AVPlayer handles)
        "mp4", "mov", "m4v", "3gp", "3g2",
        // Audio
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "alac",
        "ac3", "eac3",
    ]

    /// Known media formats that need the FFmpeg fallback.
    static let ffmpegExtensions: Set<String> = [
        // Video
        "mkv", "avi", "webm", "ts", "mts", "m2ts", "flv", "wmv", "vob", "ogv",
        "mpg", "mpeg", "divx",
        // Audio
        "ogg", "opus", "wma", "dts", "dtshd", "ape", "mka",
    ]

    /// All extensions the player will attempt to open.
    static var allSupported: Set<String> { nativeExtensions.union(ffmpegExtensions) }

    /// Check if a URL is a supported media file.
    static func canPlay(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return allSupported.contains(ext)
    }

    /// Whether a format needs the FFmpeg fallback (not natively decodable by
    /// macOS AVKit). Unknown extensions are attempted natively first; the
    /// caller falls back if AVPlayer reports a failure.
    static func needsFFmpeg(_ url: URL) -> Bool {
        ffmpegExtensions.contains(url.pathExtension.lowercased())
    }
}
