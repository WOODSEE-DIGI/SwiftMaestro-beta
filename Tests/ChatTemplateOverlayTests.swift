import XCTest
import Jinja
@testable import SwiftMaestro

/// Renders the DeepSeek-Coder-V2-Lite chat-template overlay through the same
/// swift-jinja engine the tokenizer uses, proving the tools block, the native
/// call format, tool-result roles, and assistant tool_calls replay all render
/// into valid prompt text. (Catches template syntax errors without a model
/// load — the stock template's missing tools block is what made the Coder
/// agent tool-blind.)
final class ChatTemplateOverlayTests: XCTestCase {

    private func render(messages: [[String: Any]], tools: [[String: Any]]?) throws -> String {
        let templateSource = try XCTUnwrap(
            ChatTemplateOverlays.overlay(forModelID: "local-deepseek-coder-v2-lite"),
            "DeepSeek overlay missing")
        let template = try Jinja.Template(templateSource)
        var context: [String: Jinja.Value] = [
            "add_generation_prompt": .boolean(true),
            "bos_token": .string("<｜begin▁of▁sentence｜>"),
            "eos_token": .string("<｜end▁of▁sentence｜>"),
            "messages": .array(try messages.map { try Jinja.Value(any: $0) }),
        ]
        if let tools {
            context["tools"] = .array(try tools.map { try Jinja.Value(any: $0) })
        }
        return try template.render(context)
    }

    private let sampleTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "read_file",
            "description": "Read a file's contents",
            "parameters": [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
            ],
        ],
    ]

    func testToolsBlockRendersWithSchemas() throws {
        let out = try render(
            messages: [
                ["role": "system", "content": "You are Coder."],
                ["role": "user", "content": "Read /tmp/notes.txt"],
            ],
            tools: [sampleTool])
        XCTAssertTrue(out.contains("# Tools"), "tools preamble missing:\n\(out)")
        XCTAssertTrue(out.contains("<tools>"), "tools tag missing")
        XCTAssertTrue(out.contains("\"name\":\"read_file\"") || out.contains("\"name\": \"read_file\""),
                      "tool schema missing from prompt")
        XCTAssertTrue(out.contains("<｜tool▁calls▁begin｜>"), "native call-format example missing")
        XCTAssertTrue(out.hasSuffix("Assistant:"), "must end with the generation primer, got: \(out.suffix(40))")
        XCTAssertTrue(out.contains("User: Read /tmp/notes.txt"), "user turn mangled:\n\(out)")
    }

    func testAssistantToolCallsReplayInNativeFormat() throws {
        let out = try render(
            messages: [
                ["role": "user", "content": "Read the file"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": "call1", "type": "function",
                        "function": ["name": "read_file", "arguments": "{\"path\": \"/tmp/a.swift\"}"],
                    ]],
                ],
                ["role": "tool", "tool_call_id": "call1", "content": "file contents here"],
                ["role": "user", "content": "thanks"],
            ],
            tools: [sampleTool])
        XCTAssertTrue(
            out.contains("<｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file"),
            "assistant tool_calls not replayed in native format:\n\(out)")
        XCTAssertTrue(out.contains("{\"path\": \"/tmp/a.swift\"}"), "arguments string mangled")
        XCTAssertTrue(out.contains("<｜tool▁outputs▁begin｜>"), "tool result role not rendered")
        XCTAssertTrue(out.contains("file contents here"), "tool result content missing")
    }

    func testNoToolsRendersStockShape() throws {
        let out = try render(
            messages: [
                ["role": "system", "content": "You are Coder."],
                ["role": "user", "content": "hi"],
            ],
            tools: nil)
        XCTAssertFalse(out.contains("# Tools"), "tools preamble must not render without tools")
        XCTAssertTrue(out.contains("You are Coder."))
        XCTAssertTrue(out.hasSuffix("Assistant:"))
    }
}
