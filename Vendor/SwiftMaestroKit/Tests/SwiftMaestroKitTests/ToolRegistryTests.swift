import Testing
import MLXLMCommon
@testable import SwiftMaestroKit

@Suite("ToolRegistry")
struct ToolRegistryTests {

    @Test("register + execute round-trips through the handler")
    func registerAndExecute() async throws {
        let registry = ToolRegistry()
        let spec: ToolSpec = [
            "type": "function",
            "function": ["name": "ping", "description": "test", "parameters": [:] as [String: any Sendable]]
                as [String: any Sendable],
        ]
        await registry.register(
            ToolDefinition(name: "ping", spec: spec, category: "test") { _ in "pong" }
        )
        #expect(await registry.handles("ping"))
        #expect(await registry.handles("missing") == false)

        let call = ToolCall(function: .init(name: "ping", arguments: [:] as [String: any Sendable]))
        let result = await registry.execute(call)
        #expect(result == "pong")
    }

    @Test("schemas filters by category, always including uncategorized tools")
    func schemasFiltering() async throws {
        let registry = ToolRegistry()
        func spec(_ name: String) -> ToolSpec {
            [
                "type": "function",
                "function": ["name": name, "description": "", "parameters": [:] as [String: any Sendable]]
                    as [String: any Sendable],
            ]
        }
        await registry.register([
            ToolDefinition(name: "a", spec: spec("a"), category: "cat1") { _ in "" },
            ToolDefinition(name: "b", spec: spec("b"), category: "cat2") { _ in "" },
            ToolDefinition(name: "c", spec: spec("c"), category: nil) { _ in "" },
        ])
        let filtered = await registry.schemas(enabledCategories: ["cat1"])
        let names = Set(filtered.compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String })
        #expect(names == ["a", "c"])

        let unfiltered = await registry.schemas(enabledCategories: nil)
        #expect(unfiltered.count == 3)
    }
}
