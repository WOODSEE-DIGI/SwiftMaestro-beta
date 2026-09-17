import Foundation

/// Minimal Neocities REST API client.
/// Supports uploading files with either an API key (`Authorization: Bearer`)
/// or HTTP Basic Auth (username + password). Prefer API keys.
enum NeocitiesAPIClient {

    struct UploadResult: Sendable {
        let path: String
    }

    enum NeocitiesError: Error, LocalizedError {
        case invalidResponse
        case apiMessage(String)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Neocities."
            case .apiMessage(let msg): return msg
            case .underlying(let error): return error.localizedDescription
            }
        }
    }

    /// Upload raw data to a path on a Neocities site.
    static func upload(
        sitename: String,
        apiKey: String? = nil,
        password: String? = nil,
        path: String,
        data: Data,
        mimeType: String = "text/html"
    ) async throws -> UploadResult {
        let url = URL(string: "https://neocities.org/api/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else if let password {
            let credentials = "\(sitename):\(password)"
                .data(using: .utf8)?
                .base64EncodedString() ?? ""
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, filename: path, data: data, mimeType: mimeType)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let message = json["message"] as? String {
                throw NeocitiesError.apiMessage(message)
            }
            throw NeocitiesError.invalidResponse
        }

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let result = json["result"] as? String,
           result != "success" {
            let message = (json["message"] as? String) ?? "Unknown Neocities error"
            throw NeocitiesError.apiMessage(message)
        }

        return UploadResult(path: path)
    }

    private static func multipartBody(boundary: String, filename: String, data: Data, mimeType: String) -> Data {
        var body = Data()
        let name = (filename as NSString).lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
