import Foundation

public struct HeaderEnvelopeIssuer: Sendable {
    private let signer: TrackingSigner
    private let headerBuilder: TrackingHeaderBuilder
    private let relayBaseURL: URL

    public init(signingSecret: String, relayBaseURL: URL) {
        let signer = TrackingSigner(secret: signingSecret)
        self.signer = signer
        self.headerBuilder = TrackingHeaderBuilder(signer: signer)
        self.relayBaseURL = relayBaseURL
    }

    public func issueHeaders(from input: ComposeTrackingInput) throws -> [String: [String]] {
        var metadata = input.metadata
        metadata[TrackingHeaderNames.relayBaseURL] = relayBaseURL.absoluteString
        if let subject = input.subject {
            metadata["subject"] = subject
        }

        let envelope = TrackingHeaderEnvelope(
            messageID: input.messageID,
            sender: input.sender,
            recipients: input.recipients,
            mode: input.mode,
            metadata: metadata
        )

        return try headerBuilder.build(from: envelope)
    }

    public func token(
        messageID: String,
        recipient: String?,
        kind: TrackingTokenPayload.Kind,
        ttl: TimeInterval = 604_800
    ) throws -> String {
        let expiresAt = Date().addingTimeInterval(ttl)
        let payload = TrackingTokenPayload(
            messageID: messageID,
            recipient: recipient,
            kind: kind,
            expiresAt: expiresAt
        )
        return try signer.sign(payload)
    }

    public func pixelURL(for token: String) -> URL {
        relayBaseURL
            .appending(path: "t")
            .appending(path: "open")
            .appending(path: "\(token).gif")
    }

    /// Pixel URL with API key query param for external (PHP) relay.
    public func pixelURL(for token: String, apiKey: String) -> URL {
        var components = URLComponents(
            url: relayBaseURL
                .appending(path: "t")
                .appending(path: "open")
                .appending(path: "\(token).gif"),
            resolvingAgainstBaseURL: false
        ) ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        return components.url ?? pixelURL(for: token)
    }

    public func clickURL(for token: String, destination: URL) -> URL {
        var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/t/c/\(token)"
        components.queryItems = [URLQueryItem(name: "url", value: destination.absoluteString)]
        return components.url ?? relayBaseURL
    }

    /// Click URL with API key query param for external (PHP) relay.
    public func clickURL(for token: String, destination: URL, apiKey: String) -> URL {
        var components = URLComponents(url: relayBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/t/c/\(token)"
        components.queryItems = [
            URLQueryItem(name: "url", value: destination.absoluteString),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        return components.url ?? relayBaseURL
    }
}
