import Foundation

// MARK: - JSON-RPC 2.0 base types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: [String: ACPJSONValue]?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: [String: ACPJSONValue]?
    let error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: [String: ACPJSONValue]?
}

enum JSONRPCID: Codable, Hashable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - ACP v1 types (subset)

struct ACPInitializeRequest: Codable {
    let protocolVersion: String
    let clientCapabilities: ACPClientCapabilities?
    let clientInfo: ACPImplementation?
}

struct ACPInitializeResponse: Codable {
    let protocolVersion: String
    let agentCapabilities: ACPAgentCapabilities
    let agentInfo: ACPImplementation
}

struct ACPImplementation: Codable {
    let name: String
    let version: String
}

struct ACPClientCapabilities: Codable {
    let fs: ACPFsCapabilities?
    let terminal: Bool?
}

struct ACPFsCapabilities: Codable {
    let readTextFile: Bool?
    let writeTextFile: Bool?
}

struct ACPAgentCapabilities: Codable {
    let promptCapabilities: ACPPromptCapabilities?
    let mcpCapabilities: ACPMcpCapabilities?
    let sessionCapabilities: ACPSessionCapabilities?
}

struct ACPPromptCapabilities: Codable {
    let image: Bool?
    let audio: Bool?
    let embeddedContext: Bool?
}

struct ACPMcpCapabilities: Codable {
    let http: Bool?
    let sse: Bool?
}

struct ACPSessionCapabilities: Codable {
    let close: Bool?
    let list: Bool?
    let delete: Bool?
    let resume: Bool?
}

struct ACPNewSessionRequest: Codable {
    let cwd: String
    let additionalDirectories: [String]?
    let mcpServers: [ACPMcpServer]?
}

struct ACPMcpServer: Codable {
    let name: String
    let command: String?
    let args: [String]?
    let url: String?
}

struct ACPNewSessionResponse: Codable {
    let sessionId: String
}

struct ACPPromptRequest: Codable {
    let sessionId: String
    let prompt: [ACPContentBlock]
}

struct ACPPromptResponse: Codable {
    let stopReason: String
}

enum ACPContentBlock: Codable, Hashable {
    case text(String)
    case resourceLink(ACPResourceLink)
    case resource(ACPResource)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let inner = try ACPTextBlock(from: decoder)
            self = .text(inner.text)
        case "resource_link":
            let inner = try ACPResourceLink(from: decoder)
            self = .resourceLink(inner)
        case "resource":
            let inner = try ACPResource(from: decoder)
            self = .resource(inner)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content block type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            var inner = encoder.container(keyedBy: ACPTextBlock.CodingKeys.self)
            try inner.encode(text, forKey: .text)
        case .resourceLink(let link):
            try link.encode(to: encoder)
        case .resource(let resource):
            try resource.encode(to: encoder)
        }
    }
}

struct ACPTextBlock: Codable {
    let text: String
    enum CodingKeys: String, CodingKey { case text }
}

struct ACPResourceLink: Codable, Hashable {
    let uri: String
}

struct ACPResource: Codable, Hashable {
    let uri: String
    let mimeType: String?
    let text: String?
}

struct ACPSessionUpdateNotification: Codable {
    let sessionId: String
    let update: ACPSessionUpdate
}

enum ACPSessionUpdate: Codable {
    case message(ACPMessageUpdate)
    case toolCall(ACPToolCallUpdate)
    case toolOutput(ACPToolOutputUpdate)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message":
            self = .message(try ACPMessageUpdate(from: decoder))
        case "tool_call":
            self = .toolCall(try ACPToolCallUpdate(from: decoder))
        case "tool_output":
            self = .toolOutput(try ACPToolOutputUpdate(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown session update type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let m):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("message", forKey: .type)
            try m.encode(to: encoder)
        case .toolCall(let t):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool_call", forKey: .type)
            try t.encode(to: encoder)
        case .toolOutput(let t):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool_output", forKey: .type)
            try t.encode(to: encoder)
        }
    }
}

struct ACPMessageUpdate: Codable {
    let role: String
    let content: [ACPContentBlock]
}

struct ACPToolCallUpdate: Codable {
    let toolCallId: String
    let name: String
    let arguments: [String: ACPJSONValue]?
}

struct ACPToolOutputUpdate: Codable {
    let toolCallId: String
    let output: ACPToolOutputContent
}

enum ACPToolOutputContent: Codable {
    case text(String)
    case error(String)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let inner = try ACPTextBlock(from: decoder)
            self = .text(inner.text)
        case "error":
            let inner = try ACPTextBlock(from: decoder)
            self = .error(inner.text)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown tool output type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try container.encode("text", forKey: .type)
            var inner = encoder.container(keyedBy: ACPTextBlock.CodingKeys.self)
            try inner.encode(t, forKey: .text)
        case .error(let e):
            try container.encode("error", forKey: .type)
            var inner = encoder.container(keyedBy: ACPTextBlock.CodingKeys.self)
            try inner.encode(e, forKey: .text)
        }
    }
}

// MARK: - ACP JSON value helper

/// A minimal JSON value type for ACP payloads that don't need full static typing.
enum ACPJSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ACPJSONValue])
    case object([String: ACPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([ACPJSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: ACPJSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// MARK: - Convenience

extension ACPJSONValue {
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }
}
