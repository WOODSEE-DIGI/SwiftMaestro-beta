import Foundation

// VENDORED from apple-mail-tracker-private/Sources/TrackingRelayServer
// (2026-07-31). Was `import MailTrackerShared` — now same-module.
// Keep in sync with the private repo when the rewriter evolves.

struct RelayRewriteResult {
    let rewrittenMessage: String
    let envelope: TrackingHeaderEnvelope
    let recipient: String?
    let trackingApplied: Bool
    let rewrittenLinkCount: Int
    let openPixelURL: URL?
    let notes: [String]
}

enum RelayMessageRewriterError: Error {
    case malformedMessage
}

struct RelayMessageRewriter {
    private let headerBuilder: TrackingHeaderBuilder
    private let issuer: HeaderEnvelopeIssuer

    init(configuration: RelayConfiguration) {
        let signer = TrackingSigner(secret: configuration.signingSecret)
        self.headerBuilder = TrackingHeaderBuilder(signer: signer)
        self.issuer = HeaderEnvelopeIssuer(signingSecret: configuration.signingSecret, relayBaseURL: configuration.baseURL)
    }

    func rewrite(rawMessage: String, recipientOverride: String?) throws -> RelayRewriteResult {
        var entity = try MIMEEntity.parse(rawMessage)
        let envelope = try resolveEnvelope(entity: entity)
        let recipient = recipientOverride ?? envelope.recipients.first

        guard envelope.mode != .disabled else {
            return RelayRewriteResult(
                rewrittenMessage: rawMessage,
                envelope: envelope,
                recipient: recipient,
                trackingApplied: false,
                rewrittenLinkCount: 0,
                openPixelURL: nil,
                notes: ["Tracking mode is disabled for this message."],
            )
        }

        guard let recipient else {
            return RelayRewriteResult(
                rewrittenMessage: rawMessage,
                envelope: envelope,
                recipient: nil,
                trackingApplied: false,
                rewrittenLinkCount: 0,
                openPixelURL: nil,
                notes: ["No recipient available for per-recipient token generation."],
            )
        }

        let openToken = try issuer.token(
            messageID: envelope.messageID,
            recipient: recipient,
            kind: .open
        )
        let clickToken = try issuer.token(
            messageID: envelope.messageID,
            recipient: recipient,
            kind: .click
        )
        let openPixelURL = issuer.pixelURL(for: openToken)

        var stats = RewriteStats()
        rewriteEntity(
            &entity,
            clickToken: clickToken,
            openPixelURL: openPixelURL,
            stats: &stats
        )

        return RelayRewriteResult(
            rewrittenMessage: entity.serialized(),
            envelope: envelope,
            recipient: recipient,
            trackingApplied: stats.trackingApplied,
            rewrittenLinkCount: stats.rewrittenLinkCount,
            openPixelURL: openPixelURL,
            notes: stats.notes
        )
    }

    private func resolveEnvelope(entity: MIMEEntity) throws -> TrackingHeaderEnvelope {
        let headers = entity.headersDictionary()
        if let decoded = try? headerBuilder.decode(headers: headers) {
            return decoded
        }
        return fallbackEnvelope(headers: headers)
    }

    private func fallbackEnvelope(headers: [String: [String]]) -> TrackingHeaderEnvelope {
        let messageID = firstHeader("message-id", headers: headers)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? UUID().uuidString.lowercased()

        let sender = parseAddressList(firstHeader("from", headers: headers)).first
            ?? firstHeader("from", headers: headers)
            ?? "unknown@relay.local"

        let recipients = parseAddressList(firstHeader("to", headers: headers))
            + parseAddressList(firstHeader("cc", headers: headers))
            + parseAddressList(firstHeader("bcc", headers: headers))

        return TrackingHeaderEnvelope(
            messageID: messageID,
            sender: sender,
            recipients: Array(Set(recipients)).sorted(),
            mode: .opensAndClicks,
            metadata: [
                "subject": firstHeader("subject", headers: headers) ?? "",
                "envelope_source": "relay-fallback",
            ]
        )
    }

    private func firstHeader(_ key: String, headers: [String: [String]]) -> String? {
        if let direct = headers[key]?.first {
            return direct
        }
        return headers.first(where: { $0.key.lowercased() == key.lowercased() })?.value.first
    }

    private func parseAddressList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else {
            return []
        }

        var results: [String] = []
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let angled = try? NSRegularExpression(pattern: "<([^>]+)>", options: [])
        angled?.matches(in: value, options: [], range: fullRange).forEach { match in
            guard let range = Range(match.range(at: 1), in: value) else {
                return
            }
            results.append(String(value[range]))
        }

        if results.isEmpty {
            value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .forEach { token in
                    if token.contains("@") {
                        results.append(token)
                    }
                }
        }

        return Array(Set(results)).sorted()
    }

    private func rewriteEntity(
        _ entity: inout MIMEEntity,
        clickToken: String,
        openPixelURL: URL,
        stats: inout RewriteStats
    ) {
        if entity.isMultipart {
            for index in entity.children.indices {
                rewriteEntity(
                    &entity.children[index],
                    clickToken: clickToken,
                    openPixelURL: openPixelURL,
                    stats: &stats
                )
            }
            return
        }

        let contentType = (entity.headerValue("Content-Type") ?? "text/plain").lowercased()
        if contentType.contains("text/html") {
            let html = entity.decodedTextBody()
            let rewritten = rewriteHTML(
                html: html,
                clickToken: clickToken,
                openPixelURL: openPixelURL
            )
            entity.setDecodedTextBody(rewritten.value)
            stats.rewrittenLinkCount += rewritten.rewrittenLinks
            stats.trackingApplied = true
            if rewritten.insertedPixel {
                stats.notes.append("Injected tracking pixel into HTML body.")
            }
            return
        }

        if contentType.contains("text/plain") {
            let plain = entity.decodedTextBody()
            let rewritten = rewritePlainText(plain, clickToken: clickToken)
            if rewritten.rewrittenLinks > 0 {
                entity.setDecodedTextBody(rewritten.value)
                stats.rewrittenLinkCount += rewritten.rewrittenLinks
                stats.trackingApplied = true
                stats.notes.append("Rewrote links in plain text body.")
            }
        }
    }

    private func rewriteHTML(
        html: String,
        clickToken: String,
        openPixelURL: URL
    ) -> (value: String, rewrittenLinks: Int, insertedPixel: Bool) {
        var rewritten = html
        let linkRewrite = rewriteLinks(in: rewritten, clickToken: clickToken)
        rewritten = linkRewrite.value

        let pixelTag = "<img src=\"\(openPixelURL.absoluteString)\" width=\"1\" height=\"1\" alt=\"\" style=\"display:none;\" />"
        if rewritten.contains(openPixelURL.absoluteString) {
            return (rewritten, linkRewrite.rewrittenLinks, false)
        }

        if let bodyRange = rewritten.range(
            of: "</body>",
            options: [.caseInsensitive, .backwards]
        ) {
            rewritten.replaceSubrange(bodyRange, with: "\(pixelTag)\n</body>")
            return (rewritten, linkRewrite.rewrittenLinks, true)
        }

        rewritten += "\n\(pixelTag)"
        return (rewritten, linkRewrite.rewrittenLinks, true)
    }

    private func rewritePlainText(_ text: String, clickToken: String) -> (value: String, rewrittenLinks: Int) {
        rewriteLinks(in: text, clickToken: clickToken)
    }

    private func rewriteLinks(in text: String, clickToken: String) -> (value: String, rewrittenLinks: Int) {
        let pattern = #"https?://[^\s<>"']+|www\.[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty {
            return (text, 0)
        }

        var rewritten = text
        var rewrittenLinks = 0
        for match in matches.reversed() {
            guard let range = Range(match.range, in: rewritten) else {
                continue
            }
            let originalURLString = String(rewritten[range])
            let normalizedDestinationString: String
            if originalURLString.lowercased().hasPrefix("www.") {
                normalizedDestinationString = "https://\(originalURLString)"
            } else {
                normalizedDestinationString = originalURLString
            }
            guard let destination = URL(string: normalizedDestinationString) else {
                continue
            }
            let tracked = issuer.clickURL(for: clickToken, destination: destination).absoluteString
            rewritten.replaceSubrange(range, with: tracked)
            rewrittenLinks += 1
        }

        return (rewritten, rewrittenLinks)
    }
}

private struct RewriteStats {
    var trackingApplied = false
    var rewrittenLinkCount = 0
    var notes: [String] = []
}

private struct MIMEHeader {
    var name: String
    var value: String
}

private struct MIMEEntity {
    var headers: [MIMEHeader]
    var body: String
    var children: [MIMEEntity]
    var boundary: String?
    var preamble: String
    var epilogue: String
    var newline: String

    var isMultipart: Bool {
        boundary != nil
    }

    static func parse(_ raw: String) throws -> MIMEEntity {
        try parse(raw, defaultNewline: detectNewline(in: raw))
    }

    func serialized() -> String {
        let headerText = headers.map { "\($0.name): \($0.value)" }.joined(separator: newline)
        if !isMultipart {
            return "\(headerText)\(newline)\(newline)\(body)"
        }

        guard let boundary else {
            return "\(headerText)\(newline)\(newline)\(body)"
        }

        var output = "\(headerText)\(newline)\(newline)"
        if !preamble.isEmpty {
            output += preamble
            if !output.hasSuffix(newline) {
                output += newline
            }
        }

        for child in children {
            output += "--\(boundary)\(newline)"
            output += child.serialized()
            if !output.hasSuffix(newline) {
                output += newline
            }
        }

        output += "--\(boundary)--"
        if !epilogue.isEmpty {
            output += newline + epilogue
        }
        return output
    }

    func headerValue(_ key: String) -> String? {
        headers.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value
    }

    mutating func setHeader(_ key: String, value: String) {
        if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            headers[index].value = value
        } else {
            headers.append(MIMEHeader(name: key, value: value))
        }
    }

    func headersDictionary() -> [String: [String]] {
        var dict: [String: [String]] = [:]
        for header in headers {
            dict[header.name.lowercased(), default: []].append(header.value)
        }
        return dict
    }

    func decodedTextBody() -> String {
        let transferEncoding = (headerValue("Content-Transfer-Encoding") ?? "").lowercased()
        if transferEncoding.contains("quoted-printable") {
            return Self.decodeQuotedPrintable(body)
        }
        if transferEncoding.contains("base64") {
            return Self.decodeBase64(body)
        }
        return body
    }

    mutating func setDecodedTextBody(_ text: String) {
        body = text
        setHeader("Content-Transfer-Encoding", value: "8bit")
    }
}

private extension MIMEEntity {
    static func parse(_ raw: String, defaultNewline: String) throws -> MIMEEntity {
        guard let split = splitHeaderBody(raw, newline: defaultNewline) else {
            throw RelayMessageRewriterError.malformedMessage
        }

        let headers = parseHeaders(split.headerBlock, newline: split.newline)
        let contentType = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value ?? "text/plain"
        if let boundary = parseBoundary(contentType), contentType.lowercased().contains("multipart/") {
            let multipart = parseMultipartBody(split.bodyBlock, boundary: boundary, newline: split.newline)
            let children = try multipart.parts.map { try parse($0, defaultNewline: split.newline) }
            return MIMEEntity(
                headers: headers,
                body: "",
                children: children,
                boundary: boundary,
                preamble: multipart.preamble,
                epilogue: multipart.epilogue,
                newline: split.newline
            )
        }

        return MIMEEntity(
            headers: headers,
            body: split.bodyBlock,
            children: [],
            boundary: nil,
            preamble: "",
            epilogue: "",
            newline: split.newline
        )
    }

    static func detectNewline(in raw: String) -> String {
        raw.contains("\r\n") ? "\r\n" : "\n"
    }

    static func splitHeaderBody(_ raw: String, newline: String) -> (headerBlock: String, bodyBlock: String, newline: String)? {
        if let range = raw.range(of: "\r\n\r\n") {
            return (
                headerBlock: String(raw[..<range.lowerBound]),
                bodyBlock: String(raw[range.upperBound...]),
                newline: "\r\n"
            )
        }
        if let range = raw.range(of: "\n\n") {
            return (
                headerBlock: String(raw[..<range.lowerBound]),
                bodyBlock: String(raw[range.upperBound...]),
                newline: "\n"
            )
        }
        return nil
    }

    static func parseHeaders(_ block: String, newline: String) -> [MIMEHeader] {
        let lines = block.components(separatedBy: newline)
        var result: [MIMEHeader] = []
        var currentName: String?
        var currentValue = ""

        func flushCurrent() {
            guard let currentName else {
                return
            }
            result.append(MIMEHeader(name: currentName, value: currentValue))
        }

        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            flushCurrent()
            currentName = nil
            currentValue = ""

            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            currentName = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            currentValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        flushCurrent()
        return result
    }

    static func parseBoundary(_ contentType: String) -> String? {
        guard let boundaryRange = contentType.range(of: "boundary=", options: [.caseInsensitive]) else {
            return nil
        }
        var value = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value.removeFirst()
            return value.components(separatedBy: "\"").first
        }
        return value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseMultipartBody(_ body: String, boundary: String, newline: String) -> (preamble: String, parts: [String], epilogue: String) {
        let marker = "--\(boundary)"
        let endMarker = "--\(boundary)--"
        let lines = body.components(separatedBy: newline)

        var preambleLines: [String] = []
        var epilogueLines: [String] = []
        var partBuffers: [[String]] = []
        var currentPart: [String]?
        var seenFirstBoundary = false
        var seenClosingBoundary = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == marker {
                if let currentPart {
                    partBuffers.append(currentPart)
                }
                currentPart = []
                seenFirstBoundary = true
                continue
            }

            if trimmed == endMarker {
                if let part = currentPart {
                    partBuffers.append(part)
                    currentPart = nil
                }
                seenClosingBoundary = true
                continue
            }

            if let _ = currentPart {
                currentPart?.append(line)
                continue
            }

            if !seenFirstBoundary {
                preambleLines.append(line)
            } else if seenClosingBoundary {
                epilogueLines.append(line)
            }
        }

        if let currentPart {
            partBuffers.append(currentPart)
        }

        return (
            preamble: preambleLines.joined(separator: newline),
            parts: partBuffers.map { $0.joined(separator: newline) },
            epilogue: epilogueLines.joined(separator: newline)
        )
    }

    static func decodeQuotedPrintable(_ encoded: String) -> String {
        let bytes = Array(encoded.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2])
                {
                    output.append(high * 16 + low)
                    index += 3
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        let data = Data(output)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func decodeBase64(_ encoded: String) -> String {
        let compact = encoded
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) else {
            return encoded
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: // 0-9
            return byte - 48
        case 65 ... 70: // A-F
            return byte - 55
        case 97 ... 102: // a-f
            return byte - 87
        default:
            return nil
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
