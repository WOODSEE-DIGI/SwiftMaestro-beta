//
//  StdioTransport.swift
//  SwiftMaestro
//
//  Real MCP stdio transport implementation
//

import Foundation
import Combine

/// Real stdio transport that spawns a subprocess and communicates via JSON-RPC
actor StdioTransport {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var buffer: String = ""
    private var messageQueue: [String] = []
    private var pendingRequests: [Int64: (MCPResponse) -> Void] = [:]
    private var requestId: Int64 = 0
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    enum TransportError: Error {
        case processNotStarted
        case invalidResponse
        case timeout
        case processTerminated
    }
    
    func start(command: String, args: [String] = [], environment: [String: String] = [:]) throws {
        guard process == nil else { return }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        proc.environment = env
        
        // Create pipes for stdin/stdout
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        
        // Capture handles
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading
        
        proc.launch()
        process = proc
        
        // Set up async reading
        await setupOutputReading()
    }
    
    private func setupOutputReading() {
        Task {
            while let data = await readOutput() {
                if let json = String(data: data, encoding: .utf8) {
                    await processResponse(json)
                }
            }
        }
    }
    
    private func readOutput() async -> Data? {
        // Non-blocking read from stdout
        stdout?.waitForDataInBackgroundAndNotify()
        return stdout?.availableData
    }
    
    private func processResponse(_ json: String) async {
        // Parse JSON-RPC response
        // This is a simplified implementation
        // In production, you'd need proper message batching and parsing
        print("[MCP] Received: \(json)")
    }
    
    func sendRequest(method: String, params: [String: Any]? = nil) async throws -> MCPResponse {
        guard let stdin = stdin else {
            throw TransportError.processNotStarted
        }
        
        requestId += 1
        let id = requestId
        
        let request: JSONRPCRequest = .init(
            jsonrpc: "2.0",
            id: id,
            method: method,
            params: params
        )
        
        let jsonData = try encoder.encode(request)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        
        // Send request
        try stdin.write(contentsOf: jsonData)
        try stdin.synchronize()
        
        // Store pending request handler
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = { response in
                continuation.resume(with: response)
            }
            
            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if pendingRequests[id] != nil {
                    pendingRequests[id]!(.error(.init(code: -32000, message: "Timeout")))
                    pendingRequests.removeValue(forKey: id)
                }
            }
        }
    }
    
    func stop() async {
        process?.terminate()
        process = nil
        stdin?.closeFile()
        stdout?.closeFile()
        stderr?.closeFile()
        stdin = nil
        stdout = nil
        stderr = nil
    }
}

// MARK: - JSON-RPC Models

struct JSONRPCRequest: Encodable {
    let jsonrpc: String
    let id: Int64
    let method: String
    let params: [String: Any]?
}

struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int64?
    let result: Any?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

typealias MCPResponse = Result<JSONRPCResponse, JSONRPCError>
