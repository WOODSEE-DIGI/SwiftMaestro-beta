import Foundation
import Network

// MARK: - ExcalidrawStore

/// Manages the local HTTP server for serving Excalidraw assets and
/// provides file persistence for .excalidraw boards.
@Observable
@MainActor
final class ExcalidrawStore {
    static let shared = ExcalidrawStore()

    var serverURL: URL?
    var isServerRunning = false

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let assetsPath: String

    /// Directory for storing .excalidraw files.
    var boardsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/excalidraw-boards")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        // Locate the bundled Excalidraw assets
        if let resourcePath = Bundle.main.resourcePath {
            assetsPath = resourcePath + "/excalidraw"
        } else {
            // Fallback for development
            assetsPath = Bundle.main.bundlePath + "/Resources/excalidraw"
        }
    }

    func startServer() async throws {
        guard !isServerRunning else { return }

        let params = NWParameters()
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isServerRunning = true
                case .failed, .cancelled:
                    self?.isServerRunning = false
                    self?.listener = nil
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))

        // Read the actual port once the listener is ready
        if let port = listener.port {
            serverURL = URL(string: "http://localhost:\(port.rawValue)")!
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        for conn in connections { conn.cancel() }
        connections.removeAll()
        isServerRunning = false
        serverURL = nil
    }

    // MARK: - HTTP Request Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self.processRequest(request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                Task { @MainActor in
                    self.connections.removeAll { $0 === connection }
                }
            })
        }
    }

    private func processRequest(_ request: String) -> Data {
        // Parse the HTTP request line
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return Self.httpResponse(status: 400, body: "Bad Request")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return Self.httpResponse(status: 400, body: "Bad Request")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Only serve GET requests
        guard method == "GET" else {
            return Self.httpResponse(status: 405, body: "Method Not Allowed")
        }

        // Map URL path to local file
        let filePath = resolveFilePath(path)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: filePath) else {
            // SPA fallback: serve index.html for any missing route
            let indexPath = (assetsPath as NSString).appendingPathComponent("index.html")
            guard fileManager.fileExists(atPath: indexPath) else {
                return Self.httpResponse(status: 404, body: "Not Found")
            }
            return serveFile(indexPath, mimeType: "text/html")
        }

        let mimeType = Self.mimeType(for: filePath)
        return serveFile(filePath, mimeType: mimeType)
    }

    private func resolveFilePath(_ path: String) -> String {
        var cleanPath = path
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        if cleanPath.isEmpty {
            cleanPath = "index.html"
        }
        // Remove query string
        if let queryIndex = cleanPath.firstIndex(of: "?") {
            cleanPath = String(cleanPath[cleanPath.startIndex..<queryIndex])
        }
        return (assetsPath as NSString).appendingPathComponent(cleanPath)
    }

    private func serveFile(_ filePath: String, mimeType: String) -> Data {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            return Self.httpResponse(status: 404, body: "Not Found")
        }
        return Self.httpResponse(status: 200, mimeType: mimeType, body: fileData)
    }

    // MARK: - HTTP Response Helpers

    static func httpResponse(status: Int, mimeType: String = "text/plain", body: String) -> Data {
        httpResponse(status: status, mimeType: mimeType, body: body.data(using: .utf8) ?? Data())
    }

    static func httpResponse(status: Int, mimeType: String, body: Data) -> Data {
        var response = "HTTP/1.1 \(status) OK\r\n"
        response += "Content-Type: \(mimeType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Cache-Control: no-cache\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var data = response.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }

    static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html": return "text/html"
        case "js":   return "application/javascript"
        case "mjs":  return "application/javascript"
        case "css":  return "text/css"
        case "json": return "application/json"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "svg":  return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf":  return "font/ttf"
        case "map":  return "application/json"
        case "webp": return "image/webp"
        case "ico":  return "image/x-icon"
        case "webmanifest": return "application/manifest+json"
        default:     return "application/octet-stream"
        }
    }
}

// MARK: - Board Persistence

extension ExcalidrawStore {

    /// Lists all saved .excalidraw boards.
    func listBoards() -> [ExcalidrawBoard] {
        let dir = boardsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "excalidraw" }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                return ExcalidrawBoard(
                    name: name,
                    url: url,
                    created: attrs?[.creationDate] as? Date ?? Date(),
                    modified: attrs?[.modificationDate] as? Date ?? Date()
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Saves board data to disk.
    func saveBoard(name: String, data: String) throws {
        let url = boardsDirectory.appendingPathComponent("\(name).excalidraw")
        try data.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Loads board data from disk.
    func loadBoard(url: URL) throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Deletes a board.
    func deleteBoard(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Board Model

struct ExcalidrawBoard: Identifiable {
    let name: String
    let url: URL
    let created: Date
    let modified: Date

    var id: URL { url }
}
