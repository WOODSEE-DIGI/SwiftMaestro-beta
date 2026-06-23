import XCTest
import MLXLMCommon
@testable import SwiftMaestro

final class MaestroToolsTests: XCTestCase {

    // MARK: - handles()

    func testHandlesAllNativeTools() {
        let expectedTools = [
            "get_current_time",
            "create_project_agent", "list_workspace", "archive_project_agent",
            "create_todo_list", "add_todos", "update_todo_status", "read_todos",
            "create_plan", "edit_plan", "read_plans", "read_plan",
            "send_agent_message", "read_agent_messages",
            "memory_write", "memory_read", "memory_search", "memory_list",
            "read_file", "write_file", "list_dir",
            "create_reminder", "list_reminders", "create_calendar_event",
            "create_note", "open_url",
            "list_rules", "set_rule",
        ]

        for tool in expectedTools {
            XCTAssertTrue(MaestroTools.handles(tool), "Should handle '\(tool)'")
        }
    }

    func testHandlesDoesNotHandleUnknownTools() {
        XCTAssertFalse(MaestroTools.handles("unknown_tool"))
        XCTAssertFalse(MaestroTools.handles("execute_command"))
        XCTAssertFalse(MaestroTools.handles(""))
    }

    func testHandlesExcludesDelegationTools() {
        // ask_project_agent is handled by AgentExecutor, not MaestroTools
        XCTAssertFalse(MaestroTools.handles("ask_project_agent"))
        XCTAssertFalse(MaestroTools.handles("ask_project_agents"))
    }

    // MARK: - schemas()

    func testBaseSchemasCount() {
        let schemas = MaestroTools.schemas
        // Should have at least the getCurrentTime tool
        XCTAssertFalse(schemas.isEmpty)
    }

    func testNavigatorSchemasIncludesAllCategories() {
        let schemas = MaestroTools.schemas(navigator: true)
        let names = schemas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }

        // Base
        XCTAssertTrue(names.contains("get_current_time"))
        // Todo
        XCTAssertTrue(names.contains("create_todo_list"))
        XCTAssertTrue(names.contains("read_todos"))
        // Plan
        XCTAssertTrue(names.contains("create_plan"))
        XCTAssertTrue(names.contains("read_plans"))
        // Messaging
        XCTAssertTrue(names.contains("send_agent_message"))
        XCTAssertTrue(names.contains("read_agent_messages"))
        // Memory
        XCTAssertTrue(names.contains("memory_write"))
        XCTAssertTrue(names.contains("memory_read"))
        // Files
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        // System
        XCTAssertTrue(names.contains("create_reminder"))
        XCTAssertTrue(names.contains("open_url"))
        // Workspace (Navigator-only)
        XCTAssertTrue(names.contains("create_project_agent"))
        XCTAssertTrue(names.contains("list_workspace"))
        XCTAssertTrue(names.contains("archive_project_agent"))
        // Delegation (Navigator-only spec)
        XCTAssertTrue(names.contains("ask_project_agent"))
        XCTAssertTrue(names.contains("ask_project_agents"))
    }

    func testProjectAgentSchemasExcludesWorkspaceTools() {
        let schemas = MaestroTools.schemas(navigator: false)
        let names = schemas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }

        // Should NOT have workspace tools
        XCTAssertFalse(names.contains("create_project_agent"))
        XCTAssertFalse(names.contains("list_workspace"))
        XCTAssertFalse(names.contains("archive_project_agent"))
        XCTAssertFalse(names.contains("ask_project_agent"))
        XCTAssertFalse(names.contains("ask_project_agents"))

        // Should still have base tools
        XCTAssertTrue(names.contains("get_current_time"))
        XCTAssertTrue(names.contains("create_todo_list"))
        XCTAssertTrue(names.contains("memory_write"))
    }

    // MARK: - Tool spec structure

    func testToolSpecsHaveCorrectStructure() {
        let schemas = MaestroTools.schemas(navigator: true)
        for spec in schemas {
            XCTAssertEqual(spec["type"] as? String, "function")
            let function = spec["function"] as? [String: Any]
            XCTAssertNotNil(function, "Each spec should have a 'function' key")
            XCTAssertNotNil(function?["name"], "Function should have a 'name'")
            XCTAssertNotNil(function?["description"], "Function should have a 'description'")
            XCTAssertNotNil(function?["parameters"], "Function should have 'parameters'")
        }
    }

    // MARK: - Execute (getCurrentTime - no store needed)

    func testExecuteGetCurrentTime() async {
        let args = (try? JSONSerialization.jsonObject(with: "{}".data(using: .utf8)!))
            .flatMap { $0 as? [String: JSONValue] } ?? [:]
        let call = ToolCall(function: .init(name: "get_current_time", arguments: args))

        let result = await MaestroTools.execute(call)

        // Result should contain current_time and timezone
        XCTAssertTrue(result.contains("current_time"))
        XCTAssertTrue(result.contains("timezone"))
        // Should be valid JSON
        XCTAssertNotNil(result.data(using: .utf8))
    }

    func testExecuteUnknownToolReturnsError() async {
        let args: [String: JSONValue] = [:]
        let call = ToolCall(function: .init(name: "nonexistent_tool", arguments: args))

        let result = await MaestroTools.execute(call)

        XCTAssertTrue(result.contains("error"))
    }

    // MARK: - errorJSON

    func testErrorJSON() {
        let result = MaestroTools.errorJSON("test error")
        XCTAssertTrue(result.contains("error"))
        XCTAssertTrue(result.contains("test error"))
    }

    // MARK: - jsonString

    func testJsonString() {
        let result = MaestroTools.jsonString(["key": "value"])
        XCTAssertTrue(result.contains("key"))
        XCTAssertTrue(result.contains("value"))
    }

    // MARK: - Rules tools

    func testListRulesReturnsValidJSON() async {
        let args: [String: JSONValue] = [:]
        let call = ToolCall(function: .init(name: "list_rules", arguments: args))

        let result = await MaestroTools.execute(call)

        XCTAssertTrue(result.contains("rules"))
        XCTAssertTrue(result.contains("count"))
        XCTAssertNotNil(result.data(using: .utf8))
    }

    func testSetRuleRequiresText() async {
        let args: [String: JSONValue] = [:]
        let call = ToolCall(function: .init(name: "set_rule", arguments: args))

        let result = await MaestroTools.execute(call)

        XCTAssertTrue(result.contains("error"))
        XCTAssertTrue(result.contains("text"))
    }

    func testSetRuleCreatesNewRule() async {
        let args: [String: JSONValue] = ["text": .string("Test rule")]
        let call = ToolCall(function: .init(name: "set_rule", arguments: args))

        let result = await MaestroTools.execute(call)

        XCTAssertTrue(result.contains("status"))
        XCTAssertTrue(result.contains("ok"))
        XCTAssertTrue(result.contains("Test rule"))
    }
}
