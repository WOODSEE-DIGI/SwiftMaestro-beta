import Foundation

/// Distribution manifest for the Setup app.
///
/// The Setup app never hardcodes large-file URLs beyond the well-known
/// manifest location. Everything about a payload (URL, exact byte size,
/// SHA-256) comes from this file so a release can be updated without
/// shipping a new installer binary.
struct PayloadManifest: Codable, Sendable {
    struct Payload: Codable, Sendable {
        var url: URL
        var sizeBytes: Int64
        var sha256: String
        var displayName: String
        var summary: String
        var notes: String?
    }

    var version: String
    var full: Payload
    var light: Payload
}

enum ManifestLoader {
    /// Well-known manifest location served from the website.
    static let manifestURL = URL(string: "https://swiftmaestro.com/download/SwiftMaestro-manifest.json")!

    /// Baked-in fallback (0.5.9) so the Setup app still works offline or if
    /// the website is briefly unreachable. Values match the shipped artifacts.
    static let fallback = PayloadManifest(
        version: "0.5.9",
        full: PayloadManifest.Payload(
            url: URL(string: "https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/SwiftMaestro-0.5.9-full.pkg")!,
            sizeBytes: 42_811_488_027,
            sha256: "adf9796cca877d23425e67fc366edb6db4ff0743d106b24bf9416a35b3f57f52",
            displayName: "Full",
            summary: "All models bundled — installs fully offline.",
            notes: "Gemma 4 26B, Qwen 3.5 122B, DeepSeek Coder, WhisperKit, Swift Helper."
        ),
        light: PayloadManifest.Payload(
            url: URL(string: "https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/SwiftMaestro-0.5.9-light.pkg")!,
            sizeBytes: 16_451_827_836,
            sha256: "5b0e7b80d27724bfcd693b690980f9c1893b1b42e0be233fdf9b96fc1e015067",
            displayName: "Light",
            summary: "Smaller install — chat models download on first launch.",
            notes: "WhisperKit, Swift Helper. Gemma 4 26B and friends download on demand."
        )
    )

    static func fetch() async throws -> PayloadManifest {
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ManifestError.badResponse
        }
        return try JSONDecoder().decode(PayloadManifest.self, from: data)
    }

    enum ManifestError: LocalizedError {
        case badResponse
        var errorDescription: String? {
            "The release manifest returned an invalid response from \(manifestURL.absoluteString)."
        }
    }
}