#!/usr/bin/env swift

import Foundation

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
    
    init(jsonrpc: String = "2.0", id: Int, method: String, params: [String: AnyCodable]?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int
    let result: AnyCodable?
    let error: JSONRPCError?
    
    init(jsonrpc: String = "2.0", id: Int, result: AnyCodable?, error: JSONRPCError?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: String?
}

// MARK: - AnyCodable wrapper

struct AnyCodable: Codable {
    var value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - MCP Protocol Messages

struct ToolDefinition: Codable {
    let name: String
    let description: String
    let inputSchema: ToolSchema
}

struct ToolSchema: Codable {
    let type: String
    let properties: [String: PropertyDefinition]
    let required: [String]?
}

struct PropertyDefinition: Codable {
    let type: String
    let description: String
}

struct CallToolResponse: Codable {
    let content: [ToolContent]
    let isError: Bool
}

struct ToolContent: Codable {
    let type: String
    let text: String
}

// MARK: - Custom Error Type

enum FileSystemError: Error {
    case notFound(String)
    case permissionDenied(String)
    case readFailed(String)
    case writeFailed(String)
    case invalidPath(String)
}

// MARK: - File System Operations

class FileSystemServer {
    
    static let toolDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "read_file",
            description: "Read the complete contents of a file from the local filesystem",
            inputSchema: ToolSchema(
                type: "object",
                properties: ["path": PropertyDefinition(type: "string", description: "The absolute or relative path to the file")],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: "write_file",
            description: "Write content to a file, creating parent directories if needed",
            inputSchema: ToolSchema(
                type: "object",
                properties: [
                    "path": PropertyDefinition(type: "string", description: "The absolute or relative path to the file"),
                    "content": PropertyDefinition(type: "string", description: "The content to write to the file")
                ],
                required: ["path", "content"]
            )
        ),
        ToolDefinition(
            name: "list_directory",
            description: "List the contents of a directory",
            inputSchema: ToolSchema(
                type: "object",
                properties: ["path": PropertyDefinition(type: "string", description: "The absolute or relative path to the directory")],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: "file_info",
            description: "Get detailed information about a file or directory",
            inputSchema: ToolSchema(
                type: "object",
                properties: ["path": PropertyDefinition(type: "string", description: "The absolute or relative path to the file or directory")],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: "search_files",
            description: "Search for files matching a pattern",
            inputSchema: ToolSchema(
                type: "object",
                properties: [
                    "path": PropertyDefinition(type: "string", description: "The directory to search in"),
                    "pattern": PropertyDefinition(type: "string", description: "The filename pattern to match")
                ],
                required: ["path", "pattern"]
            )
        )
    ]
    
    func readFile(path: String) -> String {
        let absolutePath = resolvePath(path)
        
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return "File not found: \(absolutePath)"
        }
        
        guard FileManager.default.isReadableFile(atPath: absolutePath) else {
            return "Permission denied: \(absolutePath)"
        }
        
        do {
            return try String(contentsOfFile: absolutePath, encoding: .utf8)
        } catch {
            return "Failed to read file: \(error.localizedDescription)"
        }
    }
    
    func writeFile(path: String, content: String) -> String {
        let absolutePath = resolvePath(path)
        let parentDir = (absolutePath as NSString).deletingLastPathComponent
        
        if !FileManager.default.fileExists(atPath: parentDir) {
            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                return "Failed to create directory: \(error.localizedDescription)"
            }
        }
        
        do {
            try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)
            return "Successfully wrote \(content.count) bytes to \(absolutePath)"
        } catch {
            return "Failed to write file: \(error.localizedDescription)"
        }
    }
    
    func listDirectory(path: String) -> String {
        let absolutePath = resolvePath(path)
        
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return "Path not found: \(absolutePath)"
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: absolutePath)
            return contents.joined(separator: "\n")
        } catch {
            return "Failed to list directory: \(error.localizedDescription)"
        }
    }
    
    func fileInfo(path: String) -> String {
        let absolutePath = resolvePath(path)
        
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return "Path not found: \(absolutePath)"
        }
        
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: absolutePath) else {
            return "Failed to get file attributes"
        }
        
        let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        
        let info: [String: String] = [
            "path": absolutePath,
            "type": isDirectory ? "directory" : "file",
            "size": "\(attrs[.size] ?? 0)",
            "modified": "\(attrs[.modificationDate] ?? Date())"
        ]
        
        return info.map { "\($0): \($1)" }.joined(separator: "\n")
    }
    
    func searchFiles(path: String, pattern: String) -> String {
        let absolutePath = resolvePath(path)
        
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return "Not a directory: \(absolutePath)"
        }
        
        let findCommand = "find \"\(absolutePath)\" -name \"\(pattern)\" 2>/dev/null"
        let output = executeCommand(findCommand)
        
        if output.isEmpty {
            return "No files found"
        }
        
        return output
    }
    
    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        let currentDir = FileManager.default.currentDirectoryPath
        return "\(currentDir)/\(path)"
    }
    
    private func executeCommand(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Command execution error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Message Router

class MessageRouter {
    let fileSystem = FileSystemServer()
    
    func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let stderrStream = FileHandle.standardError
        stderrStream.write("Received request: \(request.method)\n".data(using: .utf8)!)
        
        switch request.method {
        case "initialize":
            return initializeResponse(id: request.id)
        case "tools/list":
            return listToolsResponse(id: request.id)
        case "tools/call":
            return callToolResponse(id: request.id, params: request.params)
        default:
            return errorResponse(id: request.id, code: -32601, message: "Method not found: \(request.method)")
        }
    }
    
    private func initializeResponse(id: Int) -> JSONRPCResponse {
        let result: [String: AnyCodable] = [
            "protocolVersion": AnyCodable("2024-11-05"),
            "capabilities": AnyCodable(["tools": AnyCodable(["listChanged": AnyCodable(true)])]),
            "serverInfo": AnyCodable(["name": AnyCodable("filesystem-mcp-server"), "version": AnyCodable("1.0.0")])
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(result), error: nil)
    }
    
    private func listToolsResponse(id: Int) -> JSONRPCResponse {
        let result: [String: AnyCodable] = [
            "tools": AnyCodable(FileSystemServer.toolDefinitions.map { AnyCodable($0.toDictionary()) })
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(result), error: nil)
    }
    
    private func callToolResponse(id: Int, params: [String: AnyCodable]?) -> JSONRPCResponse {
        guard let params = params else {
            return errorResponse(id: id, code: -32602, message: "Missing parameters")
        }
        
        guard let toolName = params["name"]?.value as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        
        let arguments = params["arguments"]?.value as? [String: Any] ?? [:]
        
        let result: CallToolResponse
        
        switch toolName {
        case "read_file":
            guard let path = arguments["path"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'path' parameter")
            }
            let content = fileSystem.readFile(path: path)
            result = CallToolResponse(content: [ToolContent(type: "text", text: content)], isError: content.contains("not found") || content.contains("denied") || content.contains("Failed"))
            
        case "write_file":
            guard let path = arguments["path"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'path' parameter")
            }
            guard let content = arguments["content"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'content' parameter")
            }
            let message = fileSystem.writeFile(path: path, content: content)
            result = CallToolResponse(content: [ToolContent(type: "text", text: message)], isError: message.contains("Failed"))
            
        case "list_directory":
            guard let path = arguments["path"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'path' parameter")
            }
            let items = fileSystem.listDirectory(path: path)
            result = CallToolResponse(content: [ToolContent(type: "text", text: items)], isError: items.contains("not found") || items.contains("Failed"))
            
        case "file_info":
            guard let path = arguments["path"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'path' parameter")
            }
            let info = fileSystem.fileInfo(path: path)
            result = CallToolResponse(content: [ToolContent(type: "text", text: info)], isError: info.contains("not found") || info.contains("Failed"))
            
        case "search_files":
            guard let path = arguments["path"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'path' parameter")
            }
            guard let pattern = arguments["pattern"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing 'pattern' parameter")
            }
            let files = fileSystem.searchFiles(path: path, pattern: pattern)
            result = CallToolResponse(content: [ToolContent(type: "text", text: files)], isError: false)
            
        default:
            return errorResponse(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
        
        return JSONRPCResponse(id: id, result: AnyCodable(result.toDictionary()), error: nil)
    }
    
    private func errorResponse(id: Int, code: Int, message: String) -> JSONRPCResponse {
        return JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: code, message: message, data: nil))
    }
}

// MARK: - Extensions

extension ToolDefinition {
    func toDictionary() -> [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema.toDictionary()]
    }
}

extension ToolSchema {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if !properties.isEmpty {
            dict["properties"] = properties.mapValues { $0.toDictionary() }
        }
        if let required = required {
            dict["required"] = required
        }
        return dict
    }
}

extension PropertyDefinition {
    func toDictionary() -> [String: Any] {
        ["type": type, "description": description]
    }
}

extension CallToolResponse {
    func toDictionary() -> [String: Any] {
        ["content": content.map { $0.toDictionary() }, "isError": isError]
    }
}

extension ToolContent {
    func toDictionary() -> [String: Any] {
        ["type": type, "text": text]
    }
}

// MARK: - Main Entry Point

func main() {
    let router = MessageRouter()
    
    let stderrStream = FileHandle.standardError
    stderrStream.write("FileSystem MCP Server v1.0.0\n".data(using: .utf8)!)
    stderrStream.write("Ready to accept JSON-RPC requests\n".data(using: .utf8)!)
    
    let stdin = FileHandle.standardInput
    let stdout = FileHandle.standardOutput
    
    var buffer = Data()
    
    while true {
        let data = stdin.readData(ofLength: 1024)
        guard data.count > 0 else { break }
        
        buffer.append(data)
        
        if let line = String(data: buffer, encoding: .utf8) {
            let lines = line.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            for line in lines {
                do {
                    let requestData = line.data(using: .utf8)!
                    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestData)
                    let response = router.handleRequest(request)
                    
                    let responseEncoder = JSONEncoder()
                    responseEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    let responseData = try responseEncoder.encode(response)
                    
                    if let responseLine = String(data: responseData, encoding: .utf8) {
                        stdout.write("\(responseLine)\n".data(using: .utf8)!)
                    }
                } catch {
                    let errorResponse = JSONRPCResponse(
                        id: 0,
                        result: nil,
                        error: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)", data: nil)
                    )
                    
                    let responseEncoder = JSONEncoder()
                    if let responseData = try? responseEncoder.encode(errorResponse),
                       let responseLine = String(data: responseData, encoding: .utf8) {
                        stdout.write("\(responseLine)\n".data(using: .utf8)!)
                    }
                }
            }
            
            buffer = Data()
        }
    }
}

main()
EOF ; echo "__SWIFTMAESTRO_CWD__=$(pwd)"