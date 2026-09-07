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

        let params = NWParameters.tcp
        // Loopback-only + reuse avoids IPv6 dual-stack bind conflicts that were
        // producing NECP_CLIENT_ACTION_ADD_FLOW EEXIST errors in the sandbox.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            final class Box: @unchecked Sendable {
                private var resumed = false
                private let continuation: CheckedContinuation<Void, Error>
                init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
                func resume(with result: Result<Void, Error>) {
                    guard !resumed else { return }
                    resumed = true
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                var hasResumed: Bool { resumed }
            }
            let box = Box(continuation)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isServerRunning = true
                        if let port = listener.port, port.rawValue != 0 {
                            self?.serverURL = URL(string: "http://localhost:\(port.rawValue)")!
                            NSLog("[ExcalidrawStore] serving on \(self?.serverURL?.absoluteString ?? "?")")
                        } else {
                            NSLog("[ExcalidrawStore] listener ready but port is invalid")
                        }
                        box.resume(with: .success(()))
                    case .failed(let error):
                        NSLog("[ExcalidrawStore] listener failed: \(error.localizedDescription)")
                        self?.isServerRunning = false
                        self?.listener = nil
                        box.resume(with: .failure(error))
                    case .cancelled:
                        self?.isServerRunning = false
                        self?.listener = nil
                        box.resume(with: .failure(CancellationError()))
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

            // Safety net: if the listener never reports a terminal state, fail after 2s.
            Task { @MainActor in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if !box.hasResumed {
                    let timeout = ExcalidrawStoreError.serverTimeout
                    NSLog("[ExcalidrawStore] \(timeout.localizedDescription)")
                    self.listener?.cancel()
                    self.listener = nil
                    box.resume(with: .failure(timeout))
                }
            }
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
            Task { @MainActor in
                let response = self.processRequest(request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                    Task { @MainActor in
                        self.connections.removeAll { $0 === connection }
                    }
                })
            }
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
        let fileExists = fileManager.fileExists(atPath: filePath)
        NSLog("[ExcalidrawStore] request path=%@ resolved=%@ exists=%@", path, filePath, fileExists ? "YES" : "NO")

        guard fileExists else {
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

        // Serve persisted .excalidraw boards through the local server so the
        // WKWebView can fetch them without hitting file:// sandbox restrictions.
        let boardPrefix = "board/"
        if cleanPath.hasPrefix(boardPrefix) {
            var name = String(cleanPath.dropFirst(boardPrefix.count))
            // URL-decode so %20 and similar characters become real spaces.
            name = name.removingPercentEncoding ?? name
            let sanitized = (name as NSString)
                .replacingOccurrences(of: "..", with: "")
                .replacingOccurrences(of: "/", with: "_")
            return boardsDirectory.appendingPathComponent(sanitized).path
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
        var response = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
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

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html": return "text/html"
        case "js":   return "application/javascript"
        case "mjs":  return "application/javascript"
        case "css":  return "text/css"
        case "json", "excalidraw": return "application/json"
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

    /// Returns a localhost URL that serves the given board file through the
    /// embedded Excalidraw server. Returns nil if the server is not running.
    func serverURL(for boardURL: URL) -> URL? {
        guard let base = serverURL else { return nil }
        let name = boardURL.deletingPathExtension().lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        // appendingPathComponent treats the argument as a single path segment and
        // would encode the slash; build the full path as a string instead.
        let path = "board/\(encoded).excalidraw"
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    /// Deletes a board.
    func deleteBoard(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Errors

enum ExcalidrawStoreError: LocalizedError {
    case serverTimeout

    var errorDescription: String? {
        switch self {
        case .serverTimeout:
            return "Excalidraw local server did not start within 2 seconds."
        }
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
