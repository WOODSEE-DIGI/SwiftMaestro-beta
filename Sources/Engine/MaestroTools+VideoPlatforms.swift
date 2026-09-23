import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native tools for video-sharing platforms
//
// These tools read OAuth / API access tokens from the Keychain (by secret name)
// so the user can upload videos directly from Publish to YouTube, Vimeo, and
// eventually other platforms. Tokens must be obtained outside the app and stored
// in the Keychain (Settings → Secrets or the `security` CLI).

extension MaestroTools {

    static func registerVideoPlatformTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "upload_youtube_video",
                spec: videoPlatformToolSpecs[0],
                category: ToolCategory.youtube.rawValue,
                handler: { call in await uploadYouTubeVideo(call) }),
            ToolDefinition(
                name: "upload_vimeo_video",
                spec: videoPlatformToolSpecs[1],
                category: ToolCategory.vimeo.rawValue,
                handler: { call in await uploadVimeoVideo(call) }),
        ])
    }

    static var videoPlatformToolSpecs: [ToolSpec] {
        [
            rawSpec("upload_youtube_video",
                "Upload a local video file directly to a YouTube channel using the YouTube Data API.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file (MP4, MOV, etc.)."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video title."] as [String: any Sendable],
                    "description": ["type": "string", "description": "Video description."] as [String: any Sendable],
                    "tags": ["type": "array", "items": ["type": "string"] as [String: any Sendable], "description": "Optional list of tags."] as [String: any Sendable],
                    "privacy_status": ["type": "string", "description": "public, unlisted, or private. Default unlisted."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the YouTube OAuth 2.0 access token."] as [String: any Sendable],
                ], required: ["video_path", "title", "secret_name"]),
            rawSpec("upload_vimeo_video",
                "Upload a local video file directly to a Vimeo account using the Vimeo API.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file (MP4, MOV, etc.)."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video title."] as [String: any Sendable],
                    "description": ["type": "string", "description": "Video description."] as [String: any Sendable],
                    "privacy": ["type": "string", "description": "anybody, nobody, password, or unlisted. Default unlisted."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Vimeo API access token."] as [String: any Sendable],
                ], required: ["video_path", "title", "secret_name"]),
        ]
    }

    // MARK: - Args

    private struct UploadYouTubeVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let description: String?
        let tags: [String]?
        let privacy_status: String?
        let secret_name: String?
    }

    private struct UploadVimeoVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let description: String?
        let privacy: String?
        let secret_name: String?
    }

    // MARK: - YouTube

    private static func uploadYouTubeVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadYouTubeVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_youtube_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_youtube_video requires 'title'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_youtube_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_youtube_video could not read video file at \(path)")
        }

        let privacy = (args.privacy_status ?? "unlisted").lowercased()
        let validPrivacy = Set(["public", "unlisted", "private"])
        guard validPrivacy.contains(privacy) else {
            return errorJSON("upload_youtube_video privacy_status must be public, unlisted, or private")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "YouTube")
            let mimeType = mimeTypeForVideo(fileURL)

            let metadata: [String: any Sendable] = [
                "snippet": [
                    "title": title,
                    "description": args.description ?? "",
                    "tags": args.tags ?? [],
                    "categoryId": "22", // People & Blogs
                ] as [String: any Sendable],
                "status": [
                    "privacyStatus": privacy,
                    "selfDeclaredMadeForKids": false,
                ] as [String: any Sendable],
            ]

            let boundary = "SwiftMaestro_\(UUID().uuidString)"
            let body = try multipartRelatedBody(boundary: boundary, metadata: metadata, mediaData: data, mediaMimeType: mimeType)

            guard var components = URLComponents(string: "https://www.googleapis.com/upload/youtube/v3/videos") else {
                return errorJSON("upload_youtube_video invalid upload URL")
            }
            components.queryItems = [
                URLQueryItem(name: "uploadType", value: "multipart"),
                URLQueryItem(name: "part", value: "snippet,status"),
            ]
            guard let url = components.url else {
                return errorJSON("upload_youtube_video invalid upload URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            request.httpBody = body

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return errorJSON("upload_youtube_video non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("upload_youtube_video API returned \(http.statusCode): \(String(data: responseData, encoding: .utf8) ?? "")")
            }
            guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let videoID = object["id"] as? String else {
                return errorJSON("upload_youtube_video response did not contain a video id")
            }
            return jsonString(["uploaded": true, "id": videoID, "url": "https://youtube.com/watch?v=\(videoID)"])
        } catch {
            return errorJSON("upload_youtube_video failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Vimeo

    private static func uploadVimeoVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadVimeoVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_vimeo_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_vimeo_video requires 'title'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_vimeo_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_vimeo_video could not read video file at \(path)")
        }

        let privacy = (args.privacy ?? "unlisted").lowercased()
        let validPrivacy = Set(["anybody", "nobody", "password", "unlisted"])
        guard validPrivacy.contains(privacy) else {
            return errorJSON("upload_vimeo_video privacy must be anybody, nobody, password, or unlisted")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Vimeo")

            // Step 1: create an upload ticket.
            let ticketBody: [String: any Sendable] = [
                "name": title,
                "description": args.description ?? "",
                "privacy": ["view": privacy] as [String: any Sendable],
                "upload": [
                    "approach": "post",
                    "size": data.count,
                ] as [String: any Sendable],
            ]

            var ticketRequest = URLRequest(url: URL(string: "https://api.vimeo.com/me/videos")!)
            ticketRequest.httpMethod = "POST"
            ticketRequest.timeoutInterval = 60
            ticketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            ticketRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ticketRequest.setValue("application/vnd.vimeo.*+json;version=3.4", forHTTPHeaderField: "Accept")
            ticketRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            ticketRequest.httpBody = try JSONSerialization.data(withJSONObject: ticketBody)

            let (ticketData, ticketResponse) = try await URLSession.shared.data(for: ticketRequest)
            guard let ticketHTTP = ticketResponse as? HTTPURLResponse else {
                return errorJSON("upload_vimeo_video non-HTTP ticket response")
            }
            guard (200..<300).contains(ticketHTTP.statusCode) else {
                return errorJSON("upload_vimeo_video ticket creation returned \(ticketHTTP.statusCode): \(String(data: ticketData, encoding: .utf8) ?? "")")
            }
            guard let ticketObject = try? JSONSerialization.jsonObject(with: ticketData) as? [String: Any],
                  let uri = ticketObject["uri"] as? String,
                  let uploadInfo = ticketObject["upload"] as? [String: Any],
                  let uploadLink = uploadInfo["upload_link"] as? String,
                  let uploadURL = URL(string: uploadLink) else {
                return errorJSON("upload_vimeo_video ticket did not contain an upload link")
            }

            // Step 2: upload the file to the returned upload link.
            let boundary = "SwiftMaestro_\(UUID().uuidString)"
            let fileBody = multipartFormBody(boundary: boundary, fieldName: "file_data", filename: fileURL.lastPathComponent, data: data, mimeType: mimeTypeForVideo(fileURL))

            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.timeoutInterval = 300
            uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            uploadRequest.httpBody = fileBody

            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
            guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
                return errorJSON("upload_vimeo_video non-HTTP upload response")
            }
            guard (200..<300).contains(uploadHTTP.statusCode) else {
                return errorJSON("upload_vimeo_video file upload returned \(uploadHTTP.statusCode): \(String(data: uploadData, encoding: .utf8) ?? "")")
            }

            let videoID = uri.replacingOccurrences(of: "/videos/", with: "")
            return jsonString(["uploaded": true, "id": videoID, "uri": uri, "url": "https://vimeo.com/\(videoID)"])
        } catch {
            return errorJSON("upload_vimeo_video failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shared helpers

    private static func mimeTypeForVideo(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "m4v": return "video/x-m4v"
        default: return "video/mp4"
        }
    }

    private static func multipartRelatedBody(
        boundary: String,
        metadata: [String: any Sendable],
        mediaData: Data,
        mediaMimeType: String
    ) throws -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mediaMimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(mediaData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func multipartFormBody(
        boundary: String,
        fieldName: String,
        filename: String,
        data: Data,
        mimeType: String
    ) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
