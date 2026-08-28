import XCTest
import MLXLMCommon
@testable import SwiftMaestro

/// Round-trip tests for the DeepSeek tool-call dialect
/// (`<｜tool▁calls▁begin｜>…<｜tool▁calls▁end｜>` with ```json arguments),
/// which DeepSeek-Coder-V2-Lite emits natively. The exact fixture strings are
/// from a live mlx_lm generation against the bundled checkpoint.
final class DeepSeekToolCallParserTests: XCTestCase {

    private let parser = DeepSeekToolCallParser()

    /// Verbatim single-call output observed from the bundled model.
    private let liveSample = """
        <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file
        ```json
        {"path": "/tmp/notes.txt"}
        ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
        """

    func testParsesLiveSingleCall() {
        let call = parser.parse(content: liveSample, tools: nil)
        XCTAssertEqual(call?.function.name, "read_file")
        XCTAssertEqual(call?.function.arguments["path"]?.anyValue as? String, "/tmp/notes.txt")
    }

    func testParsesMultipleCallsFromOneBlock() {
        let text = """
            <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file
            ```json
            {"path": "/tmp/a.swift"}
            ```<｜tool▁call▁end｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>execute_command
            ```json
            {"command": "swift build"}
            ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
            """
        let calls = parser.parseEOS(text, tools: nil)
        XCTAssertEqual(calls.map(\.function.name), ["read_file", "execute_command"])
        XCTAssertEqual(
            calls.last?.function.arguments["command"]?.anyValue as? String, "swift build")
    }

    func testEndTruncatedByStopTokenStillParsesViaEOS() {
        // When <｜tool▁calls▁end｜> is a stop token it is intercepted at the id
        // level and never detokenized — the buffer ends after the call's own
        // end tag and parseEOS must still recover the call.
        let truncated = """
            <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>write_file
            ```json
            {"path": "/tmp/a.swift", "content": "print(1)"}
            ```<｜tool▁call▁end｜>
            """
        let calls = parser.parseEOS(truncated, tools: nil)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.function.name, "write_file")
        XCTAssertEqual(
            calls.first?.function.arguments["content"]?.anyValue as? String, "print(1)")
    }

    func testRejectsUndeclaredToolWhenSchemasProvided() {
        let tools: [[String: any Sendable]] = [
            ["function": ["name": "read_file"]]
        ]
        let text = liveSample.replacingOccurrences(of: "read_file", with: "delete_everything")
        XCTAssertNil(parser.parse(content: text, tools: tools))
    }

    func testPlainTextReturnsNil() {
        XCTAssertNil(parser.parse(content: "just prose, no calls", tools: nil))
        XCTAssertEqual(parser.parseEOS("just prose, no calls", tools: nil), [])
    }

    func testMalformedJSONReturnsNil() {
        let text = """
            <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>read_file
            ```json
            {"path": broken
            ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
            """
        XCTAssertNil(parser.parse(content: text, tools: nil))
    }
}
