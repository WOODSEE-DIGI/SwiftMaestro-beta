import XCTest
import MLXLMCommon
import GRDB
import SwiftMaestroKit
@testable import SwiftMaestro

/// Covers the new `ToolRegistry` mechanism directly, plus a real end-to-end
/// proof that `MaestroTools.execute(...)` actually routes a migrated tool
/// (execute_sqlite, the first group moved off the legacy switch) through the
/// registry rather than just "didn't crash" — a genuinely different tool
/// against a real temp SQLite file, not a mock.
final class ToolRegistryTests: XCTestCase {

    // MARK: - Registry mechanics (isolated, not the shared singleton)

    func testRegisterAndExecute() async {
        let registry = ToolRegistry()
        await registry.register(
            ToolDefinition(
                name: "test_echo",
                spec: ["type": "function", "function": ["name": "test_echo"] as [String: any Sendable]],
                category: "test",
                handler: { _ in "echoed" }
            )
        )
        let handles = await registry.handles("test_echo")
        XCTAssertTrue(handles)
        let result = await registry.execute(ToolCall(function: .init(name: "test_echo", arguments: [:])))
        XCTAssertEqual(result, "echoed")
    }

    func testUnregisteredToolReturnsError() async {
        let registry = ToolRegistry()
        let result = await registry.execute(ToolCall(function: .init(name: "nonexistent", arguments: [:])))
        XCTAssertTrue(result.contains("unknown tool"))
    }

    func testSchemasFilterByCategory() async {
        let registry = ToolRegistry()
        await registry.register([
            ToolDefinition(
                name: "a", spec: ["type": "function", "function": ["name": "a"] as [String: any Sendable]],
                category: "alpha", handler: { _ in "" }),
            ToolDefinition(
                name: "b", spec: ["type": "function", "function": ["name": "b"] as [String: any Sendable]],
                category: "beta", handler: { _ in "" }),
            ToolDefinition(
                name: "c", spec: ["type": "function", "function": ["name": "c"] as [String: any Sendable]],
                category: nil, handler: { _ in "" }), // uncategorized - always included
        ])
        let filtered = await registry.schemas(enabledCategories: ["alpha"])
        let names = filtered.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("c")) // uncategorized always passes
        XCTAssertFalse(names.contains("b"))
    }

    func testSchemasUnfilteredWhenCategoriesNil() async {
        let registry = ToolRegistry()
        await registry.register(
            ToolDefinition(
                name: "a", spec: ["type": "function", "function": ["name": "a"] as [String: any Sendable]],
                category: "alpha", handler: { _ in "" })
        )
        let all = await registry.schemas(enabledCategories: nil)
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Parameter alias repair (Gemma 4 drifts: filepath vs path)

    private func makeSpec(parameters: [String]) -> ToolSpec {
        var props: [String: any Sendable] = [:]
        for p in parameters { props[p] = ["type": "string"] as [String: any Sendable] }
        return [
            "type": "function",
            "function": [
                "name": "x",
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": parameters,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    func testParameterAliasRemapThroughExecute() async {
        let registry = ToolRegistry()
        await registry.register(
            ToolDefinition(
                name: "read_thing", spec: makeSpec(parameters: ["path"]), category: "test",
                handler: { call in
                    if case .string(let p)? = call.function.arguments["path"] { return "path=\(p)" }
                    return "missing"
                })
        )
        let result = await registry.execute(ToolCall(function: .init(
            name: "read_thing", arguments: ["filepath": .string("/tmp/x")])))
        XCTAssertEqual(result, "path=/tmp/x")
    }

    func testParameterAliasNeverOverwritesCanonical() async {
        let registry = ToolRegistry()
        await registry.register(
            ToolDefinition(
                name: "read_thing", spec: makeSpec(parameters: ["path"]), category: "test",
                handler: { call in
                    if case .string(let p)? = call.function.arguments["path"] { return "path=\(p)" }
                    return "missing"
                })
        )
        let result = await registry.execute(ToolCall(function: .init(
            name: "read_thing",
            arguments: ["path": .string("/real"), "filepath": .string("/decoy")])))
        XCTAssertEqual(result, "path=/real")
    }

    func testParameterAliasSkippedWhenAliasIsDeclared() async {
        // The tool declares BOTH path and file — `file` is a real parameter
        // here, so it must NOT be folded into path even though path is missing.
        let registry = ToolRegistry()
        await registry.register(
            ToolDefinition(
                name: "read_thing", spec: makeSpec(parameters: ["path", "file"]), category: "test",
                handler: { call in
                    if case .string(let f)? = call.function.arguments["file"] { return "file=\(f)" }
                    return "missing"
                })
        )
        let result = await registry.execute(ToolCall(function: .init(
            name: "read_thing", arguments: ["file": .string("/keep-separate")])))
        XCTAssertEqual(result, "file=/keep-separate")
    }

    // MARK: - Real end-to-end proof: execute_sqlite via the shared registry

    func testExecuteSQLiteDispatchesThroughSharedRegistry() async throws {
        // A real temp SQLite file, not a mock - proves the whole path
        // (MaestroTools.execute -> ToolRegistry.shared -> executeSQLite ->
        // real GRDB query) actually works after migration. Registration must
        // happen before ANY execute_sqlite call in this process — XCTest
        // never runs the app's own startup .task, and execute_sqlite was
        // removed from the legacy switch fallback entirely (the registry is
        // now its ONLY dispatch path), so an unregistered call here would
        // genuinely fail, not just skip a nice-to-have.
        await MaestroTools.registerAllMigratedTools()

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-registry-test-\(UUID().uuidString).sqlite").path
        // execute_sqlite enforces the same authorized-folders policy as file
        // tools; the raw system temp dir isn't authorized by default (this
        // failed with a real "access denied" on the first attempt — proof
        // the registry path really did reach the real security check, not a
        // mock). `workingDirectory` is treated as an implicit authorized root.
        let previousWorkingDirectory = MaestroTools.workingDirectory
        MaestroTools.workingDirectory = FileManager.default.temporaryDirectory.path
        defer {
            MaestroTools.workingDirectory = previousWorkingDirectory
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        // execute_sqlite requires the DB file to already exist on disk (it
        // checks file existence before running even a CREATE TABLE query),
        // AND checks for SQLite's "SQLite format 3" magic header - which
        // isn't actually written until a real transaction happens (a freshly
        // opened DatabaseQueue with no writes can leave a 0-byte file on
        // disk). Force one real write via GRDB directly first.
        let setupQueue = try DatabaseQueue(path: dbPath)
        try await setupQueue.write { db in try db.execute(sql: "CREATE TABLE _init (x)") }

        let setupResult = await MaestroTools.execute(ToolCall(function: .init(
            name: "execute_sqlite",
            arguments: [
                "path": .string(dbPath),
                "query": .string("CREATE TABLE greeting (message TEXT)"),
                "write": .string("true"),
            ]
        )))
        XCTAssertFalse(setupResult.contains("\"error\""), "setup failed: \(setupResult)")

        let insertResult = await MaestroTools.execute(ToolCall(function: .init(
            name: "execute_sqlite",
            arguments: [
                "path": .string(dbPath),
                "query": .string("INSERT INTO greeting VALUES ('hello from the registry')"),
                "write": .string("true"),
            ]
        )))
        XCTAssertFalse(insertResult.contains("\"error\""), "insert failed: \(insertResult)")

        let selectResult = await MaestroTools.execute(ToolCall(function: .init(
            name: "execute_sqlite",
            arguments: ["path": .string(dbPath), "query": .string("SELECT message FROM greeting")]
        )))
        XCTAssertTrue(selectResult.contains("hello from the registry"), "unexpected result: \(selectResult)")
    }
}
