import Dispatch
import Foundation
import Network

// VENDORED from apple-mail-tracker-private/Sources/TrackingRelayServer
// (2026-07-31). Adapted for embedding inside SwiftMaestro:
//   - `import MailTrackerShared` removed (now same-module)
//   - `start()` no longer calls dispatchMain() (the app has its own run loop)
//   - `stop()` added so the relay can be toggled from the Mail panel
// Keep in sync with the private repo when the server evolves.

struct RelayConfiguration: Sendable {
    let host: String
    let port: UInt16
    let signingSecret: String
    let baseURL: URL
    let storeURL: URL

    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RelayConfiguration {
        let host = environment["MAILTRACKER_LISTEN_HOST"] ?? "localhost"
        let port = UInt16(environment["MAILTRACKER_LISTEN_PORT"] ?? "") ?? 8087
        let signingSecret = environment["MAILTRACKER_SIGNING_SECRET"] ?? "dev-only-change-me"
        let baseURL = URL(string: environment["MAILTRACKER_BASE_URL"] ?? "http://\(host):\(port)") ?? URL(string: "http://localhost:8087")!
        let defaultStorePath = "\(FileManager.default.currentDirectoryPath)/.local/relay-store.json"
        let storePath = environment["MAILTRACKER_STORE_PATH"] ?? defaultStorePath
        let storeURL = URL(fileURLWithPath: storePath)

        return RelayConfiguration(
            host: host,
            port: port,
            signingSecret: signingSecret,
            baseURL: baseURL,
            storeURL: storeURL
        )
    }
}

enum RelayServerError: Error {
    case invalidPort(UInt16)
}

final class RelayHTTPServer: @unchecked Sendable {
    private let configuration: RelayConfiguration
    private let listener: NWListener
    private let signer: TrackingSigner
    private let store: RelayEventStore
    private let rewriter: RelayMessageRewriter
    private let queue = DispatchQueue(label: "mailtracker.relay.listener")

    init(configuration: RelayConfiguration) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RelayServerError.invalidPort(configuration.port)
        }
        self.configuration = configuration
        self.listener = try NWListener(using: .tcp, on: nwPort)
        self.signer = TrackingSigner(secret: configuration.signingSecret)
        self.store = RelayEventStore(storageURL: configuration.storeURL)
        self.rewriter = RelayMessageRewriter(configuration: configuration)
    }

    /// Starts the listener on the server's dispatch queue. Non-blocking —
    /// unlike the standalone executable, the app embedding this server has
    /// its own run loop, so no dispatchMain() here.
    func start() {
        listener.stateUpdateHandler = { [configuration] state in
            switch state {
            case .ready:
                print("[relay] listening on \(configuration.host):\(configuration.port)")
                print("[relay] persisting events at \(configuration.storeURL.path)")
            case let .failed(error):
                fputs("[relay] listener failed: \(error)\n", stderr)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection, accumulated: Data())
        }

        listener.start(queue: queue)
    }

    /// Stops the listener. The server cannot be restarted after this — create
    /// a new `RelayHTTPServer` to start again (NWListener is single-use once
    /// cancelled).
    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            let complete = isComplete || error != nil || self.isCompleteRequest(buffer)
            if complete {
                Task {
                    let response = await self.response(forRawRequest: buffer)
                    connection.send(
                        content: response.serialized(),
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )
                }
                return
            }

            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else {
            return false
        }

        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n") {
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("content-length:") {
                let value = lowercased.replacingOccurrences(of: "content-length:", with: "")
                contentLength = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }

        let bodyBytes = data.distance(from: headerRange.upperBound, to: data.endIndex)
        return bodyBytes >= contentLength
    }

    private func response(forRawRequest raw: Data) async -> HTTPResponse {
        do {
            let request = try HTTPRequest.parse(raw)
            return await route(request)
        } catch {
            return HTTPResponse.json(
                ErrorPayload(error: "invalid_request", detail: "\(error)"),
                status: 400
            )
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/health" {
            return HTTPResponse.json(["status": "ok"])
        }

        if request.method == "POST", request.path == "/v1/messages/register" {
            return await registerMessage(request)
        }

        if request.method == "POST", request.path == "/v1/relay/rewrite" {
            return await rewriteMessage(request)
        }

        if request.method == "GET", request.path == "/v1/events" {
            return await listEvents(request)
        }

        if request.method == "GET",
           let messageID = messageIDForSummaryPath(request.path)
        {
            return await messageSummary(messageID: messageID)
        }

        if request.method == "GET", request.path.hasPrefix("/t/open/") {
            let tokenPath = String(request.path.dropFirst("/t/open/".count))
            let token = tokenPath.hasSuffix(".gif") ? String(tokenPath.dropLast(4)) : tokenPath
            return await registerOpen(token: token, request: request)
        }

        if request.method == "GET", request.path.hasPrefix("/t/c/") {
            let token = String(request.path.dropFirst("/t/c/".count))
            return await registerClick(token: token, request: request)
        }

        return HTTPResponse.json(
            ErrorPayload(error: "not_found", detail: "No endpoint for \(request.method) \(request.path)"),
            status: 404
        )
    }

    private func registerMessage(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let payload = try JSONDecoder.trackingDecoder.decode(RegisterMessageRequest.self, from: request.body)
            let messageID = normalizeMessageID(payload.messageID ?? UUID().uuidString.lowercased())
            let message = TrackedMessageRecord(
                messageID: messageID,
                sender: payload.sender,
                recipients: payload.recipients,
                subject: payload.subject,
                mode: payload.trackingMode,
                metadata: payload.metadata
            )
            await store.upsert(message: message)
            let existingEvents = await store.events(messageIDs: messageIDCandidates(for: messageID))
            if !existingEvents.contains(where: { $0.type == .sent }) {
                await store.append(
                    event: TrackingEvent(
                        messageID: messageID,
                        type: .sent,
                        attributes: ["recipients": payload.recipients.joined(separator: ",")]
                    )
                )
            }

            let response = RegisterMessageResponse(
                messageID: messageID,
                pixelTemplateURL: "\(configuration.baseURL.absoluteString)/t/open/{token}.gif",
                clickTemplateURL: "\(configuration.baseURL.absoluteString)/t/c/{token}?url={url}"
            )
            return HTTPResponse.json(response, status: 201)
        } catch {
            return HTTPResponse.json(
                ErrorPayload(error: "invalid_body", detail: "\(error)"),
                status: 400
            )
        }
    }

    private func rewriteMessage(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let payload = try JSONDecoder.trackingDecoder.decode(RewriteMessageRequest.self, from: request.body)
            guard let rawData = Data(base64Encoded: payload.rawMessageBase64, options: [.ignoreUnknownCharacters]) else {
                return HTTPResponse.json(
                    ErrorPayload(error: "invalid_body", detail: "rawMessageBase64 is not valid base64."),
                    status: 400
                )
            }
            guard let rawMessage = String(data: rawData, encoding: .utf8)
                ?? String(data: rawData, encoding: .isoLatin1)
            else {
                return HTTPResponse.json(
                    ErrorPayload(error: "invalid_body", detail: "rawMessageBase64 could not be decoded into text."),
                    status: 400
                )
            }

            let rewriteResult = try rewriter.rewrite(
                rawMessage: rawMessage,
                recipientOverride: payload.recipient
            )
            let messageID = normalizeMessageID(rewriteResult.envelope.messageID)

            var metadata = rewriteResult.envelope.metadata
            metadata["rewriteApplied"] = rewriteResult.trackingApplied ? "true" : "false"
            metadata["rewrittenLinks"] = "\(rewriteResult.rewrittenLinkCount)"
            metadata["rewriteEnvelopeMessageID"] = rewriteResult.envelope.messageID

            let trackedMessage = TrackedMessageRecord(
                messageID: messageID,
                sender: rewriteResult.envelope.sender,
                recipients: rewriteResult.envelope.recipients,
                subject: rewriteResult.envelope.metadata["subject"],
                mode: rewriteResult.envelope.mode,
                createdAt: rewriteResult.envelope.createdAt,
                metadata: metadata
            )
            await store.upsert(message: trackedMessage)
            let existingEvents = await store.events(messageIDs: messageIDCandidates(for: messageID))
            if !existingEvents.contains(where: { $0.type == .sent }) {
                await store.append(
                    event: TrackingEvent(
                        messageID: messageID,
                        type: .sent,
                        timestamp: rewriteResult.envelope.createdAt,
                        recipient: rewriteResult.recipient,
                        attributes: ["source": "relay-rewrite"]
                    )
                )
            }

            let rewrittenMessageBase64 = Data(rewriteResult.rewrittenMessage.utf8).base64EncodedString()
            return HTTPResponse.json(
                RewriteMessageResponse(
                    messageID: messageID,
                    recipient: rewriteResult.recipient,
                    trackingApplied: rewriteResult.trackingApplied,
                    rewrittenLinkCount: rewriteResult.rewrittenLinkCount,
                    openPixelURL: rewriteResult.openPixelURL?.absoluteString,
                    rewrittenMessageBase64: rewrittenMessageBase64,
                    notes: rewriteResult.notes
                )
            )
        } catch {
            return HTTPResponse.json(
                ErrorPayload(error: "rewrite_failed", detail: "\(error)"),
                status: 400
            )
        }
    }

    private func registerOpen(token: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let payload = try signer.verify(token, as: TrackingTokenPayload.self)
            let messageID = normalizeMessageID(payload.messageID)
            guard payload.kind == .open else {
                return HTTPResponse.json(
                    ErrorPayload(error: "invalid_token_kind", detail: "Expected open token."),
                    status: 400
                )
            }
            if let expiresAt = payload.expiresAt, expiresAt < Date() {
                return HTTPResponse.json(
                    ErrorPayload(error: "token_expired", detail: "Open token has expired."),
                    status: 410
                )
            }

            await store.append(
                event: TrackingEvent(
                    messageID: messageID,
                    type: .open,
                    recipient: payload.recipient,
                    sourceIP: request.clientIP,
                    userAgent: request.headers["user-agent"],
                    attributes: [
                        "tokenKind": payload.kind.rawValue,
                        "openQuality": classifyOpenQuality(
                            userAgent: request.headers["user-agent"],
                            sourceIP: request.clientIP
                        ).rawValue,
                    ]
                )
            )

            return HTTPResponse.binary(
                Data.transparentPixelGIF,
                contentType: "image/gif",
                headers: [
                    "Cache-Control": "no-store, max-age=0",
                ]
            )
        } catch {
            return HTTPResponse.json(
                ErrorPayload(error: "invalid_token", detail: "\(error)"),
                status: 400
            )
        }
    }

    private func registerClick(token: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let payload = try signer.verify(token, as: TrackingTokenPayload.self)
            let messageID = normalizeMessageID(payload.messageID)
            guard payload.kind == .click else {
                return HTTPResponse.json(
                    ErrorPayload(error: "invalid_token_kind", detail: "Expected click token."),
                    status: 400
                )
            }
            if let expiresAt = payload.expiresAt, expiresAt < Date() {
                return HTTPResponse.json(
                    ErrorPayload(error: "token_expired", detail: "Click token has expired."),
                    status: 410
                )
            }

            let destination = request.query["url"] ?? configuration.baseURL.absoluteString
            await store.append(
                event: TrackingEvent(
                    messageID: messageID,
                    type: .click,
                    recipient: payload.recipient,
                    sourceIP: request.clientIP,
                    userAgent: request.headers["user-agent"],
                    attributes: ["destination": destination]
                )
            )

            return HTTPResponse.redirect(location: destination)
        } catch {
            return HTTPResponse.json(
                ErrorPayload(error: "invalid_token", detail: "\(error)"),
                status: 400
            )
        }
    }

    private func listEvents(_ request: HTTPRequest) async -> HTTPResponse {
        if let messageID = request.query["messageId"] {
            let events = await store.events(messageIDs: messageIDCandidates(for: messageID))
            return HTTPResponse.json(EventListResponse(events: events))
        }

        let events = await store.events(messageID: nil)
        return HTTPResponse.json(EventListResponse(events: events))
    }

    private func messageSummary(messageID: String) async -> HTTPResponse {
        let candidates = messageIDCandidates(for: messageID)
        let events = await store.events(messageIDs: candidates)
        let message = await store.message(messageIDs: candidates)

        guard !events.isEmpty || message != nil else {
            return HTTPResponse.json(
                ErrorPayload(error: "not_found", detail: "No message found for id \(messageID)"),
                status: 404
            )
        }

        let resolvedMessageID = message?.messageID ?? events.first?.messageID ?? normalizeMessageID(messageID)

        let sentEvents = events.filter { $0.type == .sent }
        let openEvents = events.filter { $0.type == .open }
        let clickEvents = events.filter { $0.type == .click }
        let replyEvents = events.filter { $0.type == .reply }

        var openQualityCounts: [String: Int] = [:]
        for event in openEvents {
            let quality = event.attributes["openQuality"] ?? OpenSignalQuality.unknown.rawValue
            openQualityCounts[quality, default: 0] += 1
        }

        let uniqueOpenRecipients = Set(openEvents.compactMap(\.recipient)).count
        let uniqueClickRecipients = Set(clickEvents.compactMap(\.recipient)).count

        let summary = MessageTrackingSummary(
            messageID: resolvedMessageID,
            subject: message?.subject,
            sender: message?.sender,
            recipients: message?.recipients ?? [],
            mode: message?.mode,
            totalEvents: events.count,
            sentCount: sentEvents.count,
            openCount: openEvents.count,
            clickCount: clickEvents.count,
            replyCount: replyEvents.count,
            uniqueOpenRecipients: uniqueOpenRecipients,
            uniqueClickRecipients: uniqueClickRecipients,
            firstSentAt: sentEvents.first?.timestamp,
            firstOpenedAt: openEvents.first?.timestamp,
            lastOpenedAt: openEvents.last?.timestamp,
            firstClickedAt: clickEvents.first?.timestamp,
            lastClickedAt: clickEvents.last?.timestamp,
            firstRepliedAt: replyEvents.first?.timestamp,
            lastEventAt: events.last?.timestamp,
            openQualityCounts: openQualityCounts
        )
        return HTTPResponse.json(MessageSummaryResponse(summary: summary))
    }

    private func messageIDForSummaryPath(_ path: String) -> String? {
        let prefix = "/v1/messages/"
        let suffix = "/summary"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else {
            return nil
        }

        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else {
            return nil
        }

        let encodedMessageID = String(path[start..<end])
        return encodedMessageID.removingPercentEncoding ?? encodedMessageID
    }

    private func normalizeMessageID(_ messageID: String) -> String {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return trimmed
        }
        return normalized
    }

    private func messageIDCandidates(for messageID: String) -> [String] {
        var candidates: [String] = [messageID]
        let normalized = normalizeMessageID(messageID)
        if !candidates.contains(normalized) {
            candidates.append(normalized)
        }
        let wrapped = "<\(normalized)>"
        if !candidates.contains(wrapped) {
            candidates.append(wrapped)
        }
        return candidates
    }

    private func classifyOpenQuality(userAgent: String?, sourceIP: String?) -> OpenSignalQuality {
        let ua = (userAgent ?? "").lowercased()
        if ua.isEmpty {
            return .unknown
        }

        let proxyIndicators = [
            "mailprivacy",
            "icloud",
            "gmailimageproxy",
        ]
        if proxyIndicators.contains(where: { ua.contains($0) }) {
            return .likelyProxy
        }

        if ua.contains("mozilla/5.0"),
           !ua.contains("safari"),
           !ua.contains("chrome"),
           !ua.contains("firefox")
        {
            return .likelyProxy
        }

        let humanIndicators = [
            "chrome",
            "safari",
            "firefox",
            "outlook",
            "thunderbird",
            "applewebkit",
        ]
        if humanIndicators.contains(where: { ua.contains($0) }) {
            return .likelyHuman
        }

        if let sourceIP,
           sourceIP.lowercased().contains("icloud")
        {
            return .likelyProxy
        }

        return .unknown
    }
}

private struct ErrorPayload: Codable {
    let error: String
    let detail: String
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var clientIP: String? {
        headers["x-forwarded-for"] ?? headers["x-real-ip"]
    }

    static func parse(_ raw: Data) throws -> HTTPRequest {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let split = raw.range(of: delimiter) else {
            throw ParseError.malformedHeaders
        }

        let headData = raw[..<split.lowerBound]
        let bodyData = raw[split.upperBound...]
        guard let headerText = String(data: headData, encoding: .utf8) else {
            throw ParseError.invalidHeaderEncoding
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError.missingRequestLine
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw ParseError.malformedRequestLine
        }
        let method = String(requestParts[0]).uppercased()
        let rawPath = String(requestParts[1])
        let components = URLComponents(string: "http://localhost\(rawPath)")
        let path = components?.path ?? rawPath
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { item in
                (item.name, item.value ?? "")
            }
        )

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: Data(bodyData)
        )
    }
}

private enum ParseError: Error {
    case malformedHeaders
    case invalidHeaderEncoding
    case missingRequestLine
    case malformedRequestLine
}

private struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let payload = (try? JSONEncoder.trackingEncoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            reason: statusReason(status),
            headers: [
                "Content-Type": "application/json",
            ],
            body: payload
        )
    }

    static func binary(_ body: Data, contentType: String, headers: [String: String] = [:]) -> HTTPResponse {
        var mergedHeaders = headers
        mergedHeaders["Content-Type"] = contentType
        return HTTPResponse(
            status: 200,
            reason: statusReason(200),
            headers: mergedHeaders,
            body: body
        )
    }

    static func redirect(location: String) -> HTTPResponse {
        HTTPResponse(
            status: 302,
            reason: statusReason(302),
            headers: ["Location": location],
            body: Data()
        )
    }

    func serialized() -> Data {
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = "\(body.count)"
        mergedHeaders["Connection"] = "close"

        var headerString = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in mergedHeaders.keys.sorted() {
            if let value = mergedHeaders[key] {
                headerString += "\(key): \(value)\r\n"
            }
        }
        headerString += "\r\n"

        var bytes = Data(headerString.utf8)
        bytes.append(body)
        return bytes
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 201:
            return "Created"
        case 302:
            return "Found"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 410:
            return "Gone"
        default:
            return "OK"
        }
    }
}

private struct RelayStoreSnapshot: Codable {
    let messages: [String: TrackedMessageRecord]
    let events: [TrackingEvent]
}

private actor RelayEventStore {
    private let storageURL: URL
    private var messages: [String: TrackedMessageRecord]
    private var trackingEvents: [TrackingEvent]

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let snapshot = try? JSONDecoder.trackingDecoder.decode(RelayStoreSnapshot.self, from: data)
        {
            self.messages = snapshot.messages
            self.trackingEvents = snapshot.events
        } else {
            self.messages = [:]
            self.trackingEvents = []
        }
    }

    func upsert(message: TrackedMessageRecord) {
        messages[message.messageID] = message
        persist()
    }

    func append(event: TrackingEvent) {
        trackingEvents.append(event)
        persist()
    }

    func events(messageID: String?) -> [TrackingEvent] {
        let filtered = trackingEvents.filter { event in
            guard let messageID else {
                return true
            }
            return event.messageID == messageID
        }
        return filtered.sorted { $0.timestamp < $1.timestamp }
    }

    func events(messageIDs: [String]) -> [TrackingEvent] {
        let candidates = Set(messageIDs)
        let filtered = trackingEvents.filter { event in
            candidates.contains(event.messageID)
        }
        return filtered.sorted { $0.timestamp < $1.timestamp }
    }

    func message(messageID: String) -> TrackedMessageRecord? {
        messages[messageID]
    }

    func message(messageIDs: [String]) -> TrackedMessageRecord? {
        for messageID in messageIDs {
            if let message = messages[messageID] {
                return message
            }
        }
        return nil
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = RelayStoreSnapshot(messages: messages, events: trackingEvents)
            let data = try JSONEncoder.trackingEncoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            fputs("[relay] persistence error: \(error)\n", stderr)
        }
    }
}

private extension Data {
    static let transparentPixelGIF = Data(
        [
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
            0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
            0x01, 0x00, 0x3B,
        ]
    )
}
