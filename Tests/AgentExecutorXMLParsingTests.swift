import Foundation
import XCTest
import MLXLMCommon
import SwiftMaestroKit
@testable import SwiftMaestro

final class AgentExecutorXMLParsingTests: XCTestCase {

    // MARK: - Helpers

    private var webToolSpecs: [ToolSpec] { MaestroTools.webToolSpecs }

    private func arguments(for call: RoundToolCall) -> [String: Any]? {
        guard let data = call.arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Named parameter form

    func testNamedParameterParsesQuery() {
        let xml = #"""
        <tool_call><function=web_search><parameter=query>swift 6.3 release notes</parameter></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "web_search")
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
    }

    // MARK: - Bare key/value pair form

    func testBareKeyValuePairsMapToCorrectKeys() {
        // Gemma 4 frequently emits parameter names as a bare <parameter> value,
        // followed by the actual value as a second bare <parameter>.
        let xml = #"""
        <tool_call><function=web_search>
        <parameter>query</parameter>
        <parameter>swift 6.3 release notes latest features</parameter>
        </function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "web_search")
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes latest features")
    }

    func testBareKeyValuePairsWithNewlines() {
        let xml = """
        <tool_call><function=web_search>
        <parameter>
        query
        </parameter>
        <parameter>
        swift 6.3 release notes latest features
        </parameter>
        </function></tool_call>
        """
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes latest features")
    }

    // MARK: - Bare value fallback

    func testBareValueMapsToFirstRequiredParameter() {
        // A single bare value should be mapped to the tool's required parameter.
        let xml = #"""
        <tool_call><function=web_search><parameter>swift 6.3 release notes</parameter></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
    }

    func testBareValueFallsBackToValueKeyWithoutSpecs() {
        // Without tool specs, the parser should preserve the old behavior.
        let xml = #"""
        <tool_call><function=web_search><parameter>swift 6.3 release notes</parameter></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["value"] as? String, "swift 6.3 release notes")
        XCTAssertNil(arguments(for: calls[0])?["query"])
    }

    // MARK: - Attribute forms

    func testNameAttributeForm() {
        let xml = #"""
        <tool_call><function=web_search><parameter name="query">swift 6.3 release notes</parameter></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
    }

    func testSelfClosingAttributeForm() {
        let xml = #"""
        <tool_call><function=web_search><parameter name="query" value="swift 6.3 release notes"/></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
    }

    // MARK: - JSON-wrapped value

    func testJSONStringLiteralValueMapsToQuery() {
        // The model sometimes emits a JSON-encoded string as the bare value.
        let xml = #"""
        <tool_call><function=web_search><parameter>"swift 6.3 release notes"</parameter></function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
    }

    // MARK: - Multiple tool calls

    func testMultipleBareKeyValuePairs() {
        let xml = #"""
        <tool_call><function=web_search>
        <parameter>query</parameter>
        <parameter>swift 6.3 release notes</parameter>
        </function></tool_call>
        <tool_call><function=web_search>
        <parameter>query</parameter>
        <parameter>latest Swift 6.3 features</parameter>
        </function></tool_call>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3 release notes")
        XCTAssertEqual(arguments(for: calls[1])?["query"] as? String, "latest Swift 6.3 features")
    }

    // MARK: - Bare function block

    func testBareFunctionBlock() {
        let xml = #"""
        <function=web_search><parameter>query</parameter><parameter>swift 6.3</parameter></function>
        """#
        let calls = AgentExecutor.extractToolCallsFromRawXML(xml, toolSpecs: webToolSpecs)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(arguments(for: calls[0])?["query"] as? String, "swift 6.3")
    }
}
