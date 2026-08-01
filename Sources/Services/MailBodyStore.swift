import Foundation

// MARK: - Mail body store (.emlx file reader)

/// Reads message bodies straight from Mail's on-disk .emlx files — no
/// Mail.app involvement at all. This is the primary body source for the Mail
/// panel: the JXA bridge (`AppleMailReader`) is only a fallback and is used
/// for *actions* (reply/flag/delete/compose), where Mail.app is required
/// anyway.
///
/// Mapping (verified against Mail V10):
///   messages.ROWID            == <ROWID>.emlx filename
///   mailboxes.url             == ~/Library/Mail/V10/<accountUUID>/<path>.mbox
///   files live under           <mailbox>.mbox/<storeUUID>/Data/**/Messages/
///
/// Reading files this way is instant (milliseconds), immune to Mail.app's
/// fragile Apple Event queue, and safe to prefetch aggressively.
@Observable
@MainActor
final class MailBodyStore {
    static let shared = MailBodyStore()

    enum BodyStoreError: LocalizedError {
        case badMailboxURL
        case fileNotFound
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badMailboxURL: return "Unrecognized mailbox URL."
            case .fileNotFound: return "Message file not found on disk (Mail may not have downloaded it yet)."
            case .unreadable: return "Message file couldn't be read."
            }
        }
    }

    /// Per-mailbox index: mailboxURL → (ROWID → path relative to the
    /// mailbox dir, e.g. "B266…/Data/8/7/1/Messages/178968.emlx").
    private var pathIndexes: [String: [Int64: String]] = [:]
    private var indexingMailboxes: Set<String> = []

    // MARK: - Public API

    /// Loads one message's headers + body from its .emlx file.
    func detail(for message: MailEnvelopeIndex.MessageRow) async throws -> AppleMailReader.MessageDetail {
        let fileURL = try await resolveFileURL(for: message)
        let raw = try readEMLXMessage(at: fileURL)
        return try parseDetail(raw: raw, message: message)
    }

    /// Whether a body file exists for this message (used to gate prefetch).
    func hasBodyFile(for message: MailEnvelopeIndex.MessageRow) async -> Bool {
        (try? await resolveFileURL(for: message)) != nil
    }

    // MARK: - Path resolution

    private static var mailRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mail/V10", isDirectory: true)
    }

    /// maps envelope mailbox URL → the .mbox directory on disk.
    private func mailboxDirectory(for mailboxURL: String) throws -> URL {
        guard let schemeEnd = mailboxURL.range(of: "://") else { throw BodyStoreError.badMailboxURL }
        let rest = String(mailboxURL[schemeEnd.upperBound...])
        var parts = rest.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw BodyStoreError.badMailboxURL }
        let accountUUID = parts.removeFirst()
        var dir = Self.mailRoot.appendingPathComponent(accountUUID, isDirectory: true)
        for component in parts {
            let decoded = component.removingPercentEncoding ?? component
            dir = dir.appendingPathComponent(decoded + ".mbox", isDirectory: true)
        }
        return dir
    }

    /// Returns the .emlx (or .partial_emlx) file for a message, indexing the
    /// mailbox's files in the background on first access.
    private func resolveFileURL(for message: MailEnvelopeIndex.MessageRow) async throws -> URL {
        let mailboxURL = message.mailboxURL
        if pathIndexes[mailboxURL] == nil {
            try await indexMailbox(mailboxURL)
        }
        guard let index = pathIndexes[mailboxURL] else { throw BodyStoreError.fileNotFound }

        let dir = try mailboxDirectory(for: mailboxURL)
        if let rel = index[message.rowID] {
            return dir.appendingPathComponent(rel)
        }
        // The index may predate a fresh download — try the common bucket
        // locations directly before declaring a miss.
        for candidate in [
            "Data/Messages/\(message.rowID).emlx",
            "Data/Messages/\(message.rowID).partial_emlx",
        ] {
            let url = dir.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Re-index once (cheap enough) in case files appeared since.
        try await indexMailbox(mailboxURL, force: true)
        if let rel = pathIndexes[mailboxURL]?[message.rowID] {
            return dir.appendingPathComponent(rel)
        }
        throw BodyStoreError.fileNotFound
    }

    /// Walks one mailbox directory and maps ROWID → relative file path.
    /// Runs off the main actor; concurrent calls for the same mailbox
    /// collapse onto one walk.
    private func indexMailbox(_ mailboxURL: String, force: Bool = false) async throws {
        if !force, pathIndexes[mailboxURL] != nil { return }
        if indexingMailboxes.contains(mailboxURL) {
            // Another walk is in flight — wait for it.
            while indexingMailboxes.contains(mailboxURL) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }
        indexingMailboxes.insert(mailboxURL)
        defer { indexingMailboxes.remove(mailboxURL) }

        let dir = try mailboxDirectory(for: mailboxURL)
        let index: [Int64: String] = await Task.detached(priority: .utility) {
            var map: [Int64: String] = [:]
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return map }
            let basePath = dir.path + "/"
            while let fileURL = enumerator.nextObject() as? URL {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(".emlx") || name.hasSuffix(".partial_emlx") else { continue }
                let digits = name.split(separator: ".").first.map(String.init) ?? ""
                guard let rowID = Int64(digits) else { continue }
                let rel = String(fileURL.path.dropFirst(basePath.count))
                map[rowID] = rel
            }
            return map
        }.value
        pathIndexes[mailboxURL] = index
    }

    // MARK: - .emlx reading

    /// Reads an .emlx file: the first line is a decimal byte count covering
    /// the RFC822 message that follows it; a plist trailer (Mail's flags)
    /// may sit after those bytes and is ignored.
    private func readEMLXMessage(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw BodyStoreError.unreadable }
        guard let firstNewline = data.firstIndex(of: 0x0A) else { throw BodyStoreError.unreadable }
        let prefix = data[data.startIndex..<firstNewline]
        guard let byteCount = Int(String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              byteCount > 0 else { throw BodyStoreError.unreadable }
        let messageStart = firstNewline + 1
        let messageEnd = min(messageStart + byteCount, data.endIndex)
        guard messageStart < data.endIndex else { throw BodyStoreError.unreadable }
        let messageData = data[messageStart..<messageEnd]
        return String(decoding: messageData, as: UTF8.self)
    }

    // MARK: - Detail assembly

    private func parseDetail(raw: String, message: MailEnvelopeIndex.MessageRow) throws -> AppleMailReader.MessageDetail {
        let entity = try MIMEEntity.parse(raw)
        let headers = entity.headersDictionary()

        let (bodyText, bodyIsHTML) = Self.extractBody(from: entity)

        return AppleMailReader.MessageDetail(
            subject: Self.decodeRFC2047(headers["subject"]?.first ?? message.subject),
            sender: Self.decodeRFC2047(headers["from"]?.first ?? message.senderDisplay),
            to: (headers["to"]?.first ?? "").split(separator: ",").map {
                Self.decodeRFC2047($0.trimmingCharacters(in: .whitespaces))
            }.filter { !$0.isEmpty },
            cc: (headers["cc"]?.first ?? "").split(separator: ",").map {
                Self.decodeRFC2047($0.trimmingCharacters(in: .whitespaces))
            }.filter { !$0.isEmpty },
            date: message.date,
            messageID: headers["message-id"]?.first ?? "",
            content: bodyText,
            contentIsHTML: bodyIsHTML,
            isRead: message.isRead,
            isFlagged: message.isFlagged
        )
    }

    /// Prefers the first text/html part; falls back to text/plain; descends
    /// multipart trees depth-first like every mail client. Returns whether the
    /// chosen part was text/html so the view never has to re-sniff the markup
    /// (table-only emails with no <html>/<body> wrapper fool tag sniffers).
    private static func extractBody(from entity: MIMEEntity) -> (text: String, isHTML: Bool) {
        if let html = firstPart(of: entity, contentType: "text/html") {
            return (html.decodedTextBody(), true)
        }
        if let plain = firstPart(of: entity, contentType: "text/plain") {
            return (plain.decodedTextBody(), false)
        }
        if !entity.isMultipart {
            return (entity.decodedTextBody(), false)
        }
        return ("", false)
    }

    private static func firstPart(of entity: MIMEEntity, contentType: String) -> MIMEEntity? {
        if !entity.isMultipart {
            let type = (entity.headerValue("Content-Type") ?? "text/plain").lowercased()
            return type.contains(contentType) ? entity : nil
        }
        for child in entity.children {
            if let found = firstPart(of: child, contentType: contentType) {
                return found
            }
        }
        return nil
    }

    // MARK: - RFC 2047 encoded-word decoding (=?UTF-8?B?…?= / =?UTF-8?Q?…?=)

    static func decodeRFC2047(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = input
        let pattern = #"\=\?([^?]+)\?([BbQq])\?([^?]+)\?\="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let textRange = Range(match.range(at: 3), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let charset = String(result[charsetRange])
            let encoding = String(result[encodingRange]).uppercased()
            let text = String(result[textRange])
            guard let decoded = decodeEncodedWordText(text, encoding: encoding, charset: charset) else { continue }
            result.replaceSubrange(fullRange, with: decoded)
        }
        return result
    }

    private static func decodeEncodedWordText(_ text: String, encoding: String, charset: String) -> String? {
        var data: Data?
        if encoding == "B" {
            data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters])
        } else {
            // Q-encoding: '_' = space, =XX hex bytes
            var bytes: [UInt8] = []
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                if c == "_" {
                    bytes.append(0x20)
                    i = text.index(after: i)
                } else if c == "=" {
                    let next = text.index(i, offsetBy: 1, limitedBy: text.endIndex)
                    let after = text.index(i, offsetBy: 3, limitedBy: text.endIndex)
                    if let n1 = next, let n2 = after {
                        let hex = String(text[n1..<n2])
                        if let byte = UInt8(hex, radix: 16) {
                            bytes.append(byte)
                            i = n2
                            continue
                        }
                    }
                    bytes.append(contentsOf: c.utf8)
                    i = text.index(after: i)
                } else {
                    bytes.append(contentsOf: c.utf8)
                    i = text.index(after: i)
                }
            }
            data = Data(bytes)
        }
        guard let data else { return nil }
        let encodingName = charset.lowercased().contains("utf-8") ? String.Encoding.utf8 : .isoLatin1
        return String(data: data, encoding: encodingName) ?? String(data: data, encoding: .utf8)
    }
}
