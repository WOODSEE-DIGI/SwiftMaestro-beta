import CryptoKit
import Foundation

public enum TrackingSignerError: Error {
    case invalidTokenFormat
    case invalidBase64Payload
    case invalidBase64Signature
    case signatureMismatch
}

public struct TrackingSigner: Sendable {
    private let key: SymmetricKey

    public init(secret: String) {
        let normalizedSecret = secret.isEmpty ? "dev-only-change-me" : secret
        self.key = SymmetricKey(data: Data(normalizedSecret.utf8))
    }

    public func signature(for payload: Data) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(digest).base64URLEncodedString()
    }

    public func verify(signature: String, for payload: Data) -> Bool {
        guard let provided = Data(base64URLEncodedString: signature) else {
            return false
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        return provided == expected
    }

    public func sign<T: Encodable>(_ payload: T) throws -> String {
        let payloadData = try JSONEncoder.trackingEncoder.encode(payload)
        let encodedPayload = payloadData.base64URLEncodedString()
        let encodedSignature = signature(for: payloadData)
        return "\(encodedPayload).\(encodedSignature)"
    }

    public func verify<T: Decodable>(_ token: String, as type: T.Type) throws -> T {
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw TrackingSignerError.invalidTokenFormat
        }
        guard let payloadData = Data(base64URLEncodedString: String(parts[0])) else {
            throw TrackingSignerError.invalidBase64Payload
        }
        let signature = String(parts[1])
        guard Data(base64URLEncodedString: signature) != nil else {
            throw TrackingSignerError.invalidBase64Signature
        }
        guard verify(signature: signature, for: payloadData) else {
            throw TrackingSignerError.signatureMismatch
        }
        return try JSONDecoder.trackingDecoder.decode(T.self, from: payloadData)
    }
}

public extension JSONEncoder {
    static var trackingEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var trackingDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncodedString value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        if paddingLength > 0 {
            normalized += String(repeating: "=", count: paddingLength)
        }
        guard let data = Data(base64Encoded: normalized) else {
            return nil
        }
        self = data
    }
}
