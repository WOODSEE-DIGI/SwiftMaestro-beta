import Foundation

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum MCPClientError: LocalizedError {
    case invalidLaunchCommand
    case processNotRunning
    case rpcError(String)
    case malformedResponse
    case requestTimedOut(String)
    case startupFailed(String)
    case serverStopped(String)

    var errorDescription: String? {
        switch self {
        case .invalidLaunchCommand:
            return "MCP server launch command is empty."
        case .processNotRunning:
            return "MCP server process is not running."
        case .rpcError(let message):
            return "MCP server error: \(message)"
        case .malformedResponse:
            return "MCP server returned a malformed response."
        case .requestTimedOut(let method):
            return "MCP request timed out: \(method)"
        case .startupFailed(let message):
            return "MCP startup failed: \(message)"
        case .serverStopped(let message):
            return "MCP server stopped: \(message)"
        }
    }
}

actor MCPStdioClient {
    private enum FramingMode {
        case contentLength
        case newlineJSON
    }

    private let config: MCPServerConfig
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readBuffer = Data()
    private var stderrBuffer = ""
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var framingMode: FramingMode = .contentLength

    init(config: MCPServerConfig) {
        self.config = config
    }

    func startIfNeeded() async throws {
        guard process == nil else { return }

        do {
            try launchProcess()
            try await bootstrap(using: .contentLength)
            framingMode = .contentLength
        } catch {
            await shutdown()
            do {
                try launchProcess()
                try await bootstrap(using: .newlineJSON)
                framingMode = .newlineJSON
            } catch {
                await shutdown()
                throw MCPClientError.startupFailed(error.localizedDescription)
            }
        }
    }

    func listTools() async throws -> [MCPToolDefinition] {
        try await startIfNeeded()
        let resultAny = try await requestResult(
            method: "tools/list",
            params: [:],
            timeoutSeconds: max(6, config.startupTimeoutSeconds),
            mode: framingMode
        )
        guard let result = resultAny as? [String: Any] else {
            throw MCPClientError.malformedResponse
        }
        guard let rawTools = result["tools"] as? [[String: Any]] else {
            return []
        }
        return rawTools.compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            let description = raw["description"] as? String ?? ""
            let schema =
                (raw["inputSchema"] as? [String: Any])
                ?? (raw["input_schema"] as? [String: Any])
                ?? ["type": "object", "properties": [String: Any]()]
            return MCPToolDefinition(name: name, description: description, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try await startIfNeeded()
        let resultAny = try await requestResult(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments,
            ],
            timeoutSeconds: 45,
            mode: framingMode
        )
        return stringifyToolResult(resultAny)
    }

    func shutdown() async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        readBuffer = Data()

        failAllPending(with: MCPClientError.serverStopped("process terminated"))
    }

    // MARK: - Startup

    private func bootstrap(using mode: FramingMode) async throws {
        _ = try await requestResult(
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "clientInfo": [
                    "name": "SwiftMaestro",
                    "version": "0.1.0",
                ],
                "capabilities": [:] as [String: Any],
            ],
            timeoutSeconds: max(4, config.startupTimeoutSeconds),
            mode: mode
        )
        try sendNotification(method: "notifications/initialized", params: [:], mode: mode)
    }

    private func launchProcess() throws {
        let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw MCPClientError.invalidLaunchCommand
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = config.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + config.args
        }

        let trimmedWD = config.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWD, !trimmedWD.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: trimmedWD, isDirectory: true)
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env {
            environment[key] = value
        }
        process.environment = environment

        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleProcessTermination(status: proc.terminationStatus)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.handleStdoutData(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.handleStderrData(data) }
        }

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.readBuffer = Data()
        self.stderrBuffer = ""
        self.nextRequestID = 1
    }

    // MARK: - IO

    private func handleStdoutData(_ data: Data) async {
        guard !data.isEmpty else { return }
        readBuffer.append(data)
        parseReadBuffer()
    }

    private func handleStderrData(_ data: Data) async {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrBuffer.append(text)
        if stderrBuffer.count > 8_000 {
            stderrBuffer = String(stderrBuffer.suffix(8_000))
        }
    }

    private func parseReadBuffer() {
        switch framingMode {
        case .contentLength:
            parseContentLengthFrames()
        case .newlineJSON:
            parseNewlineDelimitedFrames()
        }
    }

    private func parseContentLengthFrames() {
        let separator = Data("\r\n\r\n".utf8)

        while true {
            guard let headerRange = readBuffer.range(of: separator) else { break }
            let headerData = readBuffer.subdata(in: 0..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8),
                  let contentLength = parseContentLength(from: headerText)
            else { break }

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + contentLength
            guard readBuffer.count >= bodyEnd else { break }

            let body = readBuffer.subdata(in: bodyStart..<bodyEnd)
            readBuffer.removeSubrange(0..<bodyEnd)
            handleJSONMessage(body)
        }
    }

    private func parseNewlineDelimitedFrames() {
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: 0..<newlineIndex)
            readBuffer.removeSubrange(0...newlineIndex)
            let trimmed = lineData.trimmingWhitespaceAndNewlineBytes()
            guard !trimmed.isEmpty else { continue }
            handleJSONMessage(trimmed)
        }
    }

    private func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = raw.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let value = raw.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }
        return nil
    }

    private func handleJSONMessage(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let response = object as? [String: Any]
        else { return }

        guard let idValue = response["id"], let id = intValue(from: idValue) else {
            return
        }

        if let continuation = pendingResponses.removeValue(forKey: id) {
            timeoutTasks[id]?.cancel()
            timeoutTasks[id] = nil
            continuation.resume(returning: response)
        }
    }

    private func intValue(from any: Any) -> Int? {
        if let int = any as? Int { return int }
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) }
        return nil
    }

    // MARK: - JSON-RPC

    private func requestResult(
        method: String,
        params: [String: Any],
        timeoutSeconds: Int,
        mode: FramingMode
    ) async throws -> Any {
        let response = try await requestEnvelope(
            method: method,
            params: params,
            timeoutSeconds: timeoutSeconds,
            mode: mode
        )

        if let errorPayload = response["error"] as? [String: Any] {
            let message = (errorPayload["message"] as? String)
                ?? String(describing: errorPayload)
            throw MCPClientError.rpcError(message)
        }
        guard response["result"] != nil else {
            throw MCPClientError.malformedResponse
        }
        return response["result"] as Any
    }

    private func requestEnvelope(
        method: String,
        params: [String: Any],
        timeoutSeconds: Int,
        mode: FramingMode
    ) async throws -> [String: Any] {
        guard process?.isRunning == true, let stdinHandle else {
            throw MCPClientError.processNotRunning
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]
        let frame = try encodeFrame(payload: payload, mode: mode)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            timeoutTasks[requestID] = Task { [weak self] in
                guard let self else { return }
                let duration = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: duration)
                await self.failPendingRequest(
                    id: requestID,
                    error: MCPClientError.requestTimedOut(method)
                )
            }

            do {
                try stdinHandle.write(contentsOf: frame)
            } catch {
                timeoutTasks[requestID]?.cancel()
                timeoutTasks[requestID] = nil
                pendingResponses.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(
        method: String,
        params: [String: Any],
        mode: FramingMode
    ) throws {
        guard process?.isRunning == true, let stdinHandle else {
            throw MCPClientError.processNotRunning
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        let frame = try encodeFrame(payload: payload, mode: mode)
        try stdinHandle.write(contentsOf: frame)
    }

    private func encodeFrame(payload: [String: Any], mode: FramingMode) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload)
        switch mode {
        case .contentLength:
            var framed = Data("Content-Length: \(json.count)\r\n\r\n".utf8)
            framed.append(json)
            return framed
        case .newlineJSON:
            var framed = json
            framed.append(contentsOf: [0x0A])
            return framed
        }
    }

    // MARK: - Failure handling

    private func failPendingRequest(id: Int, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for (_, task) in timeoutTasks {
            task.cancel()
        }
        timeoutTasks.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    private func handleProcessTermination(status: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil

        let stderrSnippet = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = stderrSnippet.isEmpty ? "" : " stderr: \(stderrSnippet)"
        failAllPending(
            with: MCPClientError.serverStopped("exit code \(status).\(context)")
        )
    }

    // MARK: - Tool result formatting

    private func stringifyToolResult(_ any: Any) -> String {
        if let string = any as? String {
            return string
        }
        if let object = any as? [String: Any] {
            if let content = object["content"] as? [[String: Any]] {
                let textParts = content.compactMap { item -> String? in
                    if let text = item["text"] as? String {
                        return text
                    }
                    return nil
                }
                if !textParts.isEmpty {
                    return textParts.joined(separator: "\n")
                }
            }
            if JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: object)
        }
        if let array = any as? [Any],
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: any)
    }
}

private extension Data {
    func trimmingWhitespaceAndNewlineBytes() -> Data {
        let bytesToTrim = CharacterSet.whitespacesAndNewlines
        guard let text = String(data: self, encoding: .utf8) else { return self }
        let trimmed = text.trimmingCharacters(in: bytesToTrim)
        return Data(trimmed.utf8)
    }
}
