import Foundation

// MARK: - MIME Header

struct MIMEHeader {
    var name: String
    var value: String
}

// MARK: - MIME Entity

/// Lightweight MIME parser for email message bodies. Extracted from the
/// mail-tracking relay code to serve `MailBodyStore`'s email body parsing
/// without pulling in the full tracking infrastructure.
struct MIMEEntity {
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

// MARK: - MIME Parsing

extension MIMEEntity {

    enum ParseError: Error, LocalizedError {
        case malformedMessage

        var errorDescription: String? {
            switch self {
            case .malformedMessage: return "Malformed MIME message."
            }
        }
    }

    static func parse(_ raw: String, defaultNewline: String) throws -> MIMEEntity {
        guard let split = splitHeaderBody(raw, newline: defaultNewline) else {
            throw ParseError.malformedMessage
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
