import Foundation

public enum TrackingHeaderBuilderError: Error {
    case missingEnvelope
    case missingSignature
    case invalidEnvelopeEncoding
    case signatureMismatch
}

public struct TrackingHeaderBuilder: Sendable {
    private let signer: TrackingSigner

    public init(signer: TrackingSigner) {
        self.signer = signer
    }

    public func build(from envelope: TrackingHeaderEnvelope) throws -> [String: [String]] {
        let payload = try JSONEncoder.trackingEncoder.encode(envelope)
        return [
            TrackingHeaderNames.messageID: [envelope.messageID],
            TrackingHeaderNames.envelope: [payload.base64URLEncodedString()],
            TrackingHeaderNames.signature: [signer.signature(for: payload)],
        ]
    }

    public func decode(headers: [String: [String]]) throws -> TrackingHeaderEnvelope {
        guard let encodedEnvelope = firstHeaderValue(TrackingHeaderNames.envelope, headers: headers) else {
            throw TrackingHeaderBuilderError.missingEnvelope
        }
        guard let signature = firstHeaderValue(TrackingHeaderNames.signature, headers: headers) else {
            throw TrackingHeaderBuilderError.missingSignature
        }
        guard let payloadData = Data(base64URLEncodedString: encodedEnvelope) else {
            throw TrackingHeaderBuilderError.invalidEnvelopeEncoding
        }
        guard signer.verify(signature: signature, for: payloadData) else {
            throw TrackingHeaderBuilderError.signatureMismatch
        }
        return try JSONDecoder.trackingDecoder.decode(TrackingHeaderEnvelope.self, from: payloadData)
    }

    private func firstHeaderValue(_ key: String, headers: [String: [String]]) -> String? {
        if let direct = headers[key]?.first {
            return direct
        }
        let lowercaseKey = key.lowercased()
        return headers.first(where: { $0.key.lowercased() == lowercaseKey })?.value.first
    }
}
