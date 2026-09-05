import AppKit
import Foundation

/// Manages client/lead logo or headshot images outside the main Books database.
/// Images are copied into the app-support directory so moving the original
/// file does not break the avatar. Paths are keyed by the contact's stable id.
enum ClientAvatarStore {
    private static let folderName = "client-avatars"

    private static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
        return support.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func key(forClientID id: Int64) -> String {
        "client.avatar.path.\(id)"
    }

    private static func key(forLeadID id: Int64) -> String {
        "lead.avatar.path.\(id)"
    }

    static func avatarURL(forClientID id: Int64) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key(forClientID: id)) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func avatarURL(forLeadID id: Int64) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key(forLeadID: id)) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func setAvatar(forClientID id: Int64, from sourceURL: URL) -> URL? {
        do {
            try ensureDirectory()
            let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
            let dest = directory.appendingPathComponent("client-\(id).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            UserDefaults.standard.set(dest.path, forKey: key(forClientID: id))
            return dest
        } catch {
            return nil
        }
    }

    @discardableResult
    static func setAvatar(forLeadID id: Int64, from sourceURL: URL) -> URL? {
        do {
            try ensureDirectory()
            let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
            let dest = directory.appendingPathComponent("lead-\(id).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            UserDefaults.standard.set(dest.path, forKey: key(forLeadID: id))
            return dest
        } catch {
            return nil
        }
    }

    static func clearAvatar(forClientID id: Int64) {
        if let url = avatarURL(forClientID: id) {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: key(forClientID: id))
    }

    static func clearAvatar(forLeadID id: Int64) {
        if let url = avatarURL(forLeadID: id) {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: key(forLeadID: id))
    }
}
