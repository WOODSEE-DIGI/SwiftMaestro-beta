import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native tools for additional video-sharing platforms
//
// Supports direct video uploads where the platform exposes a public API:
// Dailymotion, PeerTube, TikTok (direct post), and VKontakte video.
// Tokens are read from the Keychain by secret name.

extension MaestroTools {

    static func registerMoreVideoPlatformTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "upload_dailymotion_video",
                spec: moreVideoPlatformToolSpecs[0],
                category: ToolCategory.dailymotion.rawValue,
                handler: { call in await uploadDailymotionVideo(call) }),
            ToolDefinition(
                name: "upload_peertube_video",
                spec: moreVideoPlatformToolSpecs[1],
                category: ToolCategory.peertube.rawValue,
                handler: { call in await uploadPeerTubeVideo(call) }),
            ToolDefinition(
                name: "upload_tiktok_video",
                spec: moreVideoPlatformToolSpecs[2],
                category: ToolCategory.tiktok.rawValue,
                handler: { call in await uploadTikTokVideo(call) }),
            ToolDefinition(
                name: "upload_vk_video",
                spec: moreVideoPlatformToolSpecs[3],
                category: ToolCategory.vk.rawValue,
                handler: { call in await uploadVKVideo(call) }),
        ])
    }

    static var moreVideoPlatformToolSpecs: [ToolSpec] {
        [
            rawSpec("upload_dailymotion_video",
                "Upload a local video file directly to a Dailymotion profile.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video title."] as [String: any Sendable],
                    "description": ["type": "string", "description": "Video description."] as [String: any Sendable],
                    "profile_id": ["type": "string", "description": "Dailymotion profile/channel ID. If empty, uses /v2/me/videos."] as [String: any Sendable],
                    "visibility": ["type": "string", "description": "public, private, or password. Default public."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Dailymotion access token."] as [String: any Sendable],
                ], required: ["video_path", "title", "secret_name"]),
            rawSpec("upload_peertube_video",
                "Upload a local video file directly to a PeerTube instance.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video title."] as [String: any Sendable],
                    "description": ["type": "string", "description": "Video description."] as [String: any Sendable],
                    "instance_url": ["type": "string", "description": "PeerTube instance base URL, e.g. https://peertube.tv."] as [String: any Sendable],
                    "channel_id": ["type": "string", "description": "PeerTube channel UUID. If empty, the first channel of the user is used."] as [String: any Sendable],
                    "privacy": ["type": "string", "description": "public, unlisted, or private. Default unlisted."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the PeerTube OAuth 2.0 access token."] as [String: any Sendable],
                ], required: ["video_path", "title", "instance_url", "secret_name"]),
            rawSpec("upload_tiktok_video",
                "Direct-post a local video file to a TikTok account using the Content Posting API.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video caption/title."] as [String: any Sendable],
                    "privacy_level": ["type": "string", "description": "PUBLIC, SELF_ONLY, FRIEND_ONLY, or MUTUAL_FOLLOW_FRIENDS. Default SELF_ONLY."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the TikTok access token (video.publish scope)."] as [String: any Sendable],
                ], required: ["video_path", "title", "secret_name"]),
            rawSpec("upload_vk_video",
                "Upload a local video file directly to VKontakte (VK) video.",
                properties: [
                    "video_path": ["type": "string", "description": "Absolute path to the local video file."] as [String: any Sendable],
                    "title": ["type": "string", "description": "Video title."] as [String: any Sendable],
                    "description": ["type": "string", "description": "Video description."] as [String: any Sendable],
                    "group_id": ["type": "string", "description": "VK group ID to upload to. If empty, uploads to the user's videos."] as [String: any Sendable],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the VK access token."] as [String: any Sendable],
                ], required: ["video_path", "title", "secret_name"]),
        ]
    }

    // MARK: - Args

    private struct UploadDailymotionVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let description: String?
        let profile_id: String?
        let visibility: String?
        let secret_name: String?
    }

    private struct UploadPeerTubeVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let description: String?
        let instance_url: String?
        let channel_id: String?
        let privacy: String?
        let secret_name: String?
    }

    private struct UploadTikTokVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let privacy_level: String?
        let secret_name: String?
    }

    private struct UploadVKVideoArgs: Decodable {
        let video_path: String?
        let title: String?
        let description: String?
        let group_id: String?
        let secret_name: String?
    }

    // MARK: - Dailymotion

    private static func uploadDailymotionVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadDailymotionVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_dailymotion_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_dailymotion_video requires 'title'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_dailymotion_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_dailymotion_video could not read video file at \(path)")
        }

        let visibility = (args.visibility ?? "public").lowercased()
        let validVisibility = Set(["public", "private", "password"])
        guard validVisibility.contains(visibility) else {
            return errorJSON("upload_dailymotion_video visibility must be public, private, or password")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Dailymotion")

            // Step 1: get upload session URL.
            var sessionRequest = URLRequest(url: URL(string: "https://api.dailymotion.com/v2/files/upload_sessions")!)
            sessionRequest.httpMethod = "POST"
            sessionRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            sessionRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            let (sessionData, sessionResponse) = try await URLSession.shared.data(for: sessionRequest)
            guard let sessionHTTP = sessionResponse as? HTTPURLResponse,
                  (200..<300).contains(sessionHTTP.statusCode),
                  let sessionObject = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
                  let uploadURLString = sessionObject["upload_url"] as? String,
                  let uploadURL = URL(string: uploadURLString) else {
                return errorJSON("upload_dailymotion_video failed to create upload session: \(String(data: sessionData, encoding: .utf8) ?? "")")
            }

            // Step 2: upload file.
            let boundary = "SwiftMaestro_\(UUID().uuidString)"
            let fileBody = multipartFormBody(boundary: boundary, fieldName: "file", filename: fileURL.lastPathComponent, data: data, mimeType: mimeTypeForVideo(fileURL))
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            uploadRequest.httpBody = fileBody

            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
            guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
                  (200..<300).contains(uploadHTTP.statusCode),
                  let uploadObject = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
                  let fileURLResult = uploadObject["url"] as? String else {
                return errorJSON("upload_dailymotion_video file upload failed: \(String(data: uploadData, encoding: .utf8) ?? "")")
            }

            // Step 3: create video.
            let profileID = args.profile_id?.trimmingCharacters(in: .whitespaces) ?? ""
            let createEndpoint = profileID.isEmpty
                ? "https://api.dailymotion.com/v2/me/videos"
                : "https://api.dailymotion.com/v2/profiles/\(profileID)/videos"
            let createBody: [String: any Sendable] = [
                "title": title,
                "description": args.description ?? "",
                "visibility": visibility,
                "is_for_kids": false,
                "category": "news",
                "source": ["file_url": fileURLResult] as [String: any Sendable],
            ]

            var createRequest = URLRequest(url: URL(string: createEndpoint)!)
            createRequest.httpMethod = "POST"
            createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            createRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            createRequest.httpBody = try JSONSerialization.data(withJSONObject: createBody)

            let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
            guard let createHTTP = createResponse as? HTTPURLResponse,
                  (200..<300).contains(createHTTP.statusCode),
                  let createObject = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
                  let videoID = createObject["video_id"] as? String ?? createObject["id"] as? String else {
                return errorJSON("upload_dailymotion_video video creation failed: \(String(data: createData, encoding: .utf8) ?? "")")
            }
            return jsonString(["uploaded": true, "id": videoID, "url": "https://dailymotion.com/video/\(videoID)"])
        } catch {
            return errorJSON("upload_dailymotion_video failed: \(error.localizedDescription)")
        }
    }

    // MARK: - PeerTube

    private static func uploadPeerTubeVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadPeerTubeVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_peertube_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_peertube_video requires 'title'")
        }
        guard let instanceURLString = args.instance_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instanceURLString.isEmpty,
              var instanceComponents = URLComponents(string: instanceURLString),
              let instanceURL = instanceComponents.url else {
            return errorJSON("upload_peertube_video requires a valid 'instance_url'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_peertube_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_peertube_video could not read video file at \(path)")
        }

        let privacyValue: Int
        switch (args.privacy ?? "unlisted").lowercased() {
        case "public": privacyValue = 1
        case "unlisted": privacyValue = 2
        case "private": privacyValue = 3
        default:
            return errorJSON("upload_peertube_video privacy must be public, unlisted, or private")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "PeerTube")

            var channelID = args.channel_id?.trimmingCharacters(in: .whitespaces) ?? ""
            if channelID.isEmpty {
                // Fetch the first channel belonging to the user.
                let channelsURL = instanceURL.appendingPathComponent("/api/v1/users/me/video-channels")
                var channelsRequest = URLRequest(url: channelsURL)
                channelsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                channelsRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
                let (channelsData, channelsResponse) = try await URLSession.shared.data(for: channelsRequest)
                guard let channelsHTTP = channelsResponse as? HTTPURLResponse,
                      (200..<300).contains(channelsHTTP.statusCode),
                      let channelsObject = try? JSONSerialization.jsonObject(with: channelsData) as? [String: Any],
                      let channels = channelsObject["data"] as? [[String: Any]],
                      let firstChannelID = channels.first?["id"] as? Int else {
                    return errorJSON("upload_peertube_video could not determine a channel; pass channel_id")
                }
                channelID = String(firstChannelID)
            }

            let uploadURL = instanceURL.appendingPathComponent("/api/v1/videos/upload")
            let boundary = "SwiftMaestro_\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
            body.append(title.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"channelId\"\r\n\r\n".data(using: .utf8)!)
            body.append(channelID.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"privacy\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(privacyValue)".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            if let description = args.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"description\"\r\n\r\n".data(using: .utf8)!)
                body.append(description.data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"videofile\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeTypeForVideo(fileURL))\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.timeoutInterval = 300
            uploadRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            uploadRequest.httpBody = body

            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
            let uploadHTTP = uploadResponse as? HTTPURLResponse
            guard uploadHTTP != nil,
                  (200..<300).contains(uploadHTTP!.statusCode),
                  let uploadObject = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any] else {
                return errorJSON("upload_peertube_video upload failed \(uploadHTTP?.statusCode ?? 0): \(String(data: uploadData, encoding: .utf8) ?? "")")
            }
            let videoID = uploadObject["id"] as? Int ?? uploadObject["uuid"] as? Int ?? 0
            let uuid = uploadObject["uuid"] as? String ?? String(videoID)
            let watchURL = "\(instanceURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/w/\(uuid)"
            return jsonString(["uploaded": true, "id": videoID, "uuid": uuid, "url": watchURL])
        } catch {
            return errorJSON("upload_peertube_video failed: \(error.localizedDescription)")
        }
    }

    // MARK: - TikTok

    private static func uploadTikTokVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadTikTokVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_tiktok_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_tiktok_video requires 'title'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_tiktok_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_tiktok_video could not read video file at \(path)")
        }

        let privacy = (args.privacy_level ?? "SELF_ONLY").uppercased()
        let validPrivacy = Set(["PUBLIC", "SELF_ONLY", "FRIEND_ONLY", "MUTUAL_FOLLOW_FRIENDS"])
        guard validPrivacy.contains(privacy) else {
            return errorJSON("upload_tiktok_video privacy_level must be PUBLIC, SELF_ONLY, FRIEND_ONLY, or MUTUAL_FOLLOW_FRIENDS")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "TikTok")

            // Step 1: initialize direct post.
            let initBody: [String: any Sendable] = [
                "post_info": [
                    "title": title,
                    "privacy_level": privacy,
                    "disable_duet": false,
                    "disable_comment": false,
                    "disable_stitch": false,
                ] as [String: any Sendable],
                "source_info": [
                    "source": "FILE_UPLOAD",
                    "video_size": data.count,
                    "chunk_size": data.count,
                    "total_chunk_count": 1,
                ] as [String: any Sendable],
            ]

            var initRequest = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/post/publish/video/init/")!)
            initRequest.httpMethod = "POST"
            initRequest.timeoutInterval = 60
            initRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            initRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            initRequest.httpBody = try JSONSerialization.data(withJSONObject: initBody)

            let (initData, initResponse) = try await URLSession.shared.data(for: initRequest)
            guard let initHTTP = initResponse as? HTTPURLResponse,
                  (200..<300).contains(initHTTP.statusCode),
                  let initObject = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
                  let dataObject = initObject["data"] as? [String: Any],
                  let publishID = dataObject["publish_id"] as? String,
                  let uploadURLString = dataObject["upload_url"] as? String,
                  let uploadURL = URL(string: uploadURLString) else {
                return errorJSON("upload_tiktok_video init failed: \(String(data: initData, encoding: .utf8) ?? "")")
            }

            // Step 2: upload the whole file in one PUT chunk.
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.timeoutInterval = 300
            uploadRequest.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
            uploadRequest.setValue("bytes 0-\(data.count - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            uploadRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            uploadRequest.httpBody = data

            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
            let uploadHTTP = uploadResponse as? HTTPURLResponse
            guard uploadHTTP != nil,
                  (200..<300).contains(uploadHTTP!.statusCode) else {
                return errorJSON("upload_tiktok_video file upload failed \(uploadHTTP?.statusCode ?? 0): \(String(data: uploadData, encoding: .utf8) ?? "")")
            }

            return jsonString(["uploaded": true, "publish_id": publishID])
        } catch {
            return errorJSON("upload_tiktok_video failed: \(error.localizedDescription)")
        }
    }

    // MARK: - VKontakte

    private static func uploadVKVideo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadVKVideoArgs.self),
              let path = args.video_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return errorJSON("upload_vk_video requires 'video_path'") }

        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return errorJSON("upload_vk_video requires 'title'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("upload_vk_video requires 'secret_name'")
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return errorJSON("upload_vk_video could not read video file at \(path)")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "VK")

            // Step 1: call video.save to obtain upload_url.
            guard var saveComponents = URLComponents(string: "https://api.vk.com/method/video.save") else {
                return errorJSON("upload_vk_video invalid video.save URL")
            }
            var queryItems = [
                URLQueryItem(name: "name", value: title),
                URLQueryItem(name: "description", value: args.description ?? ""),
                URLQueryItem(name: "v", value: "5.199"),
                URLQueryItem(name: "access_token", value: token),
            ]
            let groupID = args.group_id?.trimmingCharacters(in: .whitespaces) ?? ""
            if !groupID.isEmpty {
                queryItems.append(URLQueryItem(name: "group_id", value: groupID))
            }
            saveComponents.queryItems = queryItems
            guard let saveURL = saveComponents.url else {
                return errorJSON("upload_vk_video invalid video.save URL")
            }

            var saveRequest = URLRequest(url: saveURL)
            saveRequest.httpMethod = "POST"
            saveRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            let (saveData, saveResponse) = try await URLSession.shared.data(for: saveRequest)
            guard let saveHTTP = saveResponse as? HTTPURLResponse,
                  (200..<300).contains(saveHTTP.statusCode),
                  let saveObject = try? JSONSerialization.jsonObject(with: saveData) as? [String: Any] else {
                return errorJSON("upload_vk_video video.save failed: \(String(data: saveData, encoding: .utf8) ?? "")")
            }
            if let error = saveObject["error"] as? [String: Any],
               let errorMsg = error["error_msg"] as? String {
                return errorJSON("upload_vk_video video.save error: \(errorMsg)")
            }
            guard let response = saveObject["response"] as? [String: Any],
                  let uploadURLString = response["upload_url"] as? String,
                  let uploadURL = URL(string: uploadURLString),
                  let ownerID = response["owner_id"] as? Int,
                  let videoID = response["video_id"] as? Int else {
                return errorJSON("upload_vk_video video.save response missing upload_url")
            }

            // Step 2: upload the file to the returned upload_url.
            let boundary = "SwiftMaestro_\(UUID().uuidString)"
            let fileBody = multipartFormBody(boundary: boundary, fieldName: "video_file", filename: fileURL.lastPathComponent, data: data, mimeType: mimeTypeForVideo(fileURL))

            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.timeoutInterval = 300
            uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            uploadRequest.httpBody = fileBody

            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
            let uploadHTTP = uploadResponse as? HTTPURLResponse
            guard uploadHTTP != nil,
                  (200..<300).contains(uploadHTTP!.statusCode) else {
                return errorJSON("upload_vk_video file upload failed \(uploadHTTP?.statusCode ?? 0): \(String(data: uploadData, encoding: .utf8) ?? "")")
            }

            return jsonString(["uploaded": true, "owner_id": ownerID, "video_id": videoID, "url": "https://vk.com/video\(ownerID)_\(videoID)"])
        } catch {
            return errorJSON("upload_vk_video failed: \(error.localizedDescription)")
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
