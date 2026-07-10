import Foundation
import Network
import MLXLMCommon
import UniformTypeIdentifiers

// MARK: - Built-in Static File Server

/// Lightweight HTTP server for serving local directories over HTTP.
/// Uses Apple's Network framework (NWListener) — no Python dependency.
/// Agents call `start_server` to spin up a server, `stop_server` to tear it
/// down, and `list_servers` to see what's running.
extension MaestroTools {

    static let serverToolNames: Set<String> = [
        "start_server", "stop_server", "list_servers",
    ]

    static var serverToolSpecs: [ToolSpec] {
        [
            rawSpec("start_server",
                "Start a static HTTP file server on a local port. Serves files from a directory "
                + "so the agent can preview HTML, JSON, or images in a browser. Returns the URL "
                + "to access the server. The server stays running until stop_server is called or "
                + "the app quits.",
                properties: [
                    "port": ["type": "integer", "description": "Port number (1024-65535). Use 0 for auto-assign."],
                    "path": ["type": "string", "description": "Absolute path to the directory to serve."],
                ],
                required: ["path"]),
            rawSpec("stop_server",
                "Stop a running static file server by port number.",
                properties: [
                    "port": ["type": "integer", "description": "Port of the server to stop."],
                ],
                required: ["port"]),
            rawSpec("list_servers",
                "List all running static file servers with their URLs and served directories.",
                properties: [:] as [String: any Sendable],
                required: []),
        ]
    }

    // MARK: - Args

    private struct StartServerArgs: Decodable {
        let port: Int?
        let path: String?
    }

    private struct StopServerArgs: Decodable {
        let port: Int?
    }

    // MARK: - Dispatch

    static func startStaticServer(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: StartServerArgs.self) else {
            return errorJSON("Invalid arguments.")
        }
        let rawPath = args.path ?? ""
        let port = args.port ?? 0

        // Resolve and validate the directory
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = unescapeShellPath(expanded)
        let dirURL = URL(fileURLWithPath: resolved).standardizedFileURL

        guard FileManager.default.fileExists(atPath: dirURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: dirURL.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else {
            return errorJSON("Path is not a valid directory: \(dirURL.path)")
        }

        // Check authorization
        let roots = authorizedRootsForParent()
        guard isAllowed(dirURL.path, roots: roots) else {
            return errorJSON("Directory not authorized: \(dirURL.path). Add it in Settings → Context.")
        }

        // Check if port is already in use
        if port > 0, await StaticFileServer.shared.isPortInUse(port) {
            return errorJSON("Port \(port) is already in use by another server.")
        }

        do {
            let actualPort = try await StaticFileServer.shared.start(
                directory: dirURL.path,
                port: port > 0 ? UInt16(port) : nil
            )
            let url = "http://localhost:\(actualPort)"
            return encodeJSON(ServerStartResult(
                success: true,
                port: actualPort,
                url: url,
                directory: dirURL.path,
                message: "Server running at \(url). Open in browser to view content."
            ))
        } catch {
            return errorJSON("Failed to start server: \(error.localizedDescription)")
        }
    }

    static func stopStaticServer(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: StopServerArgs.self),
              let port = args.port else {
            return errorJSON("Provide the port number of the server to stop.")
        }
        let stopped = await StaticFileServer.shared.stop(port: UInt16(port))
        if stopped {
            return jsonString(["success": true, "message": "Server on port \(port) stopped."])
        } else {
            return errorJSON("No server found on port \(port).")
        }
    }

    static func listStaticServers() async -> String {
        let servers = await StaticFileServer.shared.listServers()
        return encodeJSON(ServerListResult(
            servers: servers,
            count: servers.count
        ))
    }
}

// MARK: - Static File Server (Network Framework)

/// Manages multiple static file servers, each serving a directory on a port.
/// Uses NWListener for the TCP server and handles HTTP requests inline.
@MainActor
private final class StaticFileServer {

    static let shared = StaticFileServer()

    /// Active servers keyed by port.
    private var servers: [UInt16: ServerInstance] = [:]

    struct ServerInstance {
        let listener: NWListener
        let directory: String
        let port: UInt16
        var connections: [NWConnection] = []
    }

    struct ServerInfo: Encodable {
        let port: Int
        let url: String
        let directory: String
    }

    func isPortInUse(_ port: Int) -> Bool {
        servers.keys.contains(UInt16(port))
    }

    func start(directory: String, port: UInt16?) async throws -> Int {
        let params = NWParameters()
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        if let port = port {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } else {
            listener = try NWListener(using: params, on: .any)
        }

        // Wait for the listener to be ready and capture the actual port
        let actualPort: UInt16 = port ?? 0

        let instance = ServerInstance(
            listener: listener,
            directory: directory,
            port: actualPort
        )
        servers[actualPort] = instance

        // Update the state handler to clean up on failure/cancel
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed:
                Task { @MainActor in
                    self.servers.removeValue(forKey: actualPort)
                }
            case .cancelled:
                Task { @MainActor in
                    self.servers.removeValue(forKey: actualPort)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection, directory: directory)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        return Int(actualPort)
    }

    func stop(port: UInt16) -> Bool {
        guard let instance = servers.removeValue(forKey: port) else { return false }
        instance.listener.cancel()
        for conn in instance.connections {
            conn.cancel()
        }
        return true
    }

    func listServers() -> [ServerInfo] {
        servers.values.map { instance in
            ServerInfo(
                port: Int(instance.port),
                url: "http://localhost:\(instance.port)",
                directory: instance.directory
            )
        }
    }

    private func handleConnection(_ connection: NWConnection, directory: String) {
        // Track connection
        for (port, var instance) in servers where instance.directory == directory {
            instance.connections.append(connection)
            servers[port] = instance
            break
        }

        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self?.processHTTPRequest(request, directory: directory) ?? Self.errorResponse(status: 500, body: "Internal error")

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func processHTTPRequest(_ request: String, directory: String) -> Data? {
        // Parse the first line: "GET /path HTTP/1.1"
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return Self.errorResponse(status: 400, body: "Bad request")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              String(parts[0]) == "GET" else {
            return Self.errorResponse(status: 405, body: "Method not allowed")
        }

        var path = String(parts[1]).removingPercentEncoding ?? String(parts[1])

        // Default to index.html
        if path == "/" { path = "/index.html" }

        // Resolve the file path
        let filePath = (directory as NSString).appendingPathComponent(path)

        // Security: prevent directory traversal
        let resolvedDir = URL(fileURLWithPath: directory).standardizedFileURL.path
        let resolvedFile = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard resolvedFile.hasPrefix(resolvedDir) else {
            return Self.errorResponse(status: 403, body: "Forbidden")
        }

        // Read the file
        guard FileManager.default.fileExists(atPath: resolvedFile) else {
            return Self.errorResponse(status: 404, body: "Not found: \(path)")
        }

        guard let fileData = FileManager.default.contents(atPath: resolvedFile) else {
            return Self.errorResponse(status: 500, body: "Failed to read file")
        }

        // Determine content type
        let contentType = Self.mimeType(for: resolvedFile)

        // Build HTTP response
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(fileData.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var headerData = response.data(using: .utf8) ?? Data()
        headerData.append(fileData)
        return headerData
    }

    private static func errorResponse(status: Int, body: String) -> Data {
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        return response.data(using: .utf8) ?? Data()
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "xml": return "application/xml"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Result Types

private struct ServerStartResult: Encodable {
    let success: Bool
    let port: Int
    let url: String
    let directory: String
    let message: String
}

private struct ServerListResult: Encodable {
    let servers: [StaticFileServer.ServerInfo]
    let count: Int
}
