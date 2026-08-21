import XCTest
import MLXLMCommon
import PDFKit
import SwiftMaestroKit
@testable import SwiftMaestro

final class MaestroToolsTests: XCTestCase {

    // MARK: - handles()

    func testHandlesAllNativeTools() async {
        // Registry-backed now (see ToolRegistry.swift) - must be populated
        // before checking, since XCTest never runs the app's own startup .task.
        await MaestroTools.registerAllMigratedTools()

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
            let handled = await MaestroTools.handles(tool)
            XCTAssertTrue(handled, "Should handle '\(tool)'")
        }
    }

    func testHandlesDoesNotHandleUnknownTools() async {
        let unknown = await MaestroTools.handles("unknown_tool")
        let empty = await MaestroTools.handles("")
        XCTAssertFalse(unknown)
        XCTAssertFalse(empty)
    }

    func testHandlesShellTools() async {
        await MaestroTools.registerAllMigratedTools()
        let executeCommand = await MaestroTools.handles("execute_command")
        let listBackground = await MaestroTools.handles("list_background_processes")
        let stopBackground = await MaestroTools.handles("stop_background_process")
        XCTAssertTrue(executeCommand)
        XCTAssertTrue(listBackground)
        XCTAssertTrue(stopBackground)
    }

    func testDelegationToolsAreRegisteredButDefendedAgainstDirectExecution() async {
        // ask_project_agent/ask_project_agents ARE registered now (so they
        // advertise correctly and handles() is accurate) - but AgentExecutor
        // intercepts them by name BEFORE ever calling MaestroTools.handles()/
        // execute() (it needs the live model/endpoint/MCP context this
        // static registry has no access to). If that interception is ever
        // bypassed, these defensive handlers must fail loudly, not silently
        // do something wrong.
        await MaestroTools.registerAllMigratedTools()
        let askOne = await MaestroTools.handles("ask_project_agent")
        let askMany = await MaestroTools.handles("ask_project_agents")
        XCTAssertTrue(askOne)
        XCTAssertTrue(askMany)

        let oneResult = await MaestroTools.execute(
            ToolCall(function: .init(name: "ask_project_agent", arguments: [:])))
        let manyResult = await MaestroTools.execute(
            ToolCall(function: .init(name: "ask_project_agents", arguments: [:])))
        XCTAssertTrue(oneResult.contains("intercepted by AgentExecutor"))
        XCTAssertTrue(manyResult.contains("intercepted by AgentExecutor"))
    }

    // MARK: - schemas()

    func testBaseSchemasCount() {
        let schemas = MaestroTools.schemas
        // Should have at least the getCurrentTime tool
        XCTAssertFalse(schemas.isEmpty)
    }

    func testNavigatorSchemasIncludesAllCategories() async {
        await MaestroTools.registerAllMigratedTools()
        let schemas = await MaestroTools.schemas(navigator: true)
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
        // Memory (Navigator keeps these for coordination context)
        XCTAssertTrue(names.contains("memory_write"))
        XCTAssertTrue(names.contains("memory_read"))
        // Files (Navigator gets basic file discovery)
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        // Indexing
        XCTAssertTrue(names.contains("index_directory"))
        XCTAssertTrue(names.contains("save_index"))
        XCTAssertTrue(names.contains("spotlight_search"))
        // OCR (Navigator-only)
        XCTAssertTrue(names.contains("ocr_image"))
        // Workspace / Delegation (Navigator-only)
        XCTAssertTrue(names.contains("create_project_agent"))
        XCTAssertTrue(names.contains("list_workspace"))
        XCTAssertTrue(names.contains("archive_project_agent"))
        XCTAssertTrue(names.contains("ask_project_agent"))
        XCTAssertTrue(names.contains("ask_project_agents"))

        // Navigator does NOT get inter-agent messaging — it must delegate that work
        // via ask_project_agent/ask_project_agents instead of messaging directly.
        XCTAssertFalse(names.contains("send_agent_message"))
        XCTAssertFalse(names.contains("read_agent_messages"))

        // Navigator DOES get system tools (Calendar/Reminders/Contacts/Shortcuts)
        // and app tools (Notes.md/Kanban/Canvas/Apple Notes) — the user wants
        // Navigator to reach as many tools as possible directly, not only
        // through delegation.
        XCTAssertTrue(names.contains("create_reminder"))
        XCTAssertTrue(names.contains("open_url"))
        XCTAssertTrue(names.contains("list_notes"))
        XCTAssertTrue(names.contains("list_kanban_boards"))
        XCTAssertTrue(names.contains("whiteboard_list_boards"))
        XCTAssertTrue(names.contains("list_numbers_documents"))
        XCTAssertTrue(names.contains("read_numbers_table"))
    }

    func testProjectAgentSchemasExcludesWorkspaceTools() async {
        await MaestroTools.registerAllMigratedTools()
        let schemas = await MaestroTools.schemas(navigator: false)
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

    func testToolSpecsHaveCorrectStructure() async {
        await MaestroTools.registerAllMigratedTools()
        let schemas = await MaestroTools.schemas(navigator: true)
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

    // MARK: - Compact Tool Mode: schemas(compactMode:)

    func testSchemasCompactModeDefaultOffIsUnchanged() async {
        await MaestroTools.registerAllMigratedTools()
        // compactMode defaults to false — a deferrable tool (read_file, .file
        // category) stays directly advertised, and the meta-tools are absent.
        let names = await MaestroTools.schemas(navigator: false).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertFalse(names.contains("search_tools"))
        XCTAssertFalse(names.contains("call_tool"))
    }

    func testSchemasCompactModeHidesDeferrableCategoriesOnly() async {
        await MaestroTools.registerAllMigratedTools()
        let names = await MaestroTools.schemas(
            navigator: false,
            enabledCategories: [.file, .memory],
            compactMode: true
        ).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        // .file is deferrable and enabled -> hidden, replaced by meta-tools.
        XCTAssertFalse(names.contains("read_file"))
        XCTAssertTrue(names.contains("search_tools"))
        XCTAssertTrue(names.contains("call_tool"))
        // .memory is NOT deferrable -> stays directly advertised even in compact mode.
        XCTAssertTrue(names.contains("memory_write"))
    }

    func testSchemasCompactModeOmitsMetaToolsWhenNothingIsDeferred() async {
        await MaestroTools.registerAllMigratedTools()
        // Only non-deferrable categories enabled -> nothing to defer -> no
        // meta-tools added (they'd be pure overhead with nothing to search).
        let names = await MaestroTools.schemas(
            navigator: false,
            enabledCategories: [.memory, .rules],
            compactMode: true
        ).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertFalse(names.contains("search_tools"))
        XCTAssertFalse(names.contains("call_tool"))
    }

    // MARK: - Compact Tool Mode: search_tools / call_tool

    func testSearchToolsFindsDeferredToolByKeyword() async {
        MaestroTools.currentIsNavigator = false
        MaestroTools.currentEnabledCategories = [.file]
        defer { MaestroTools.currentEnabledCategories = nil }

        let call = ToolCall(function: .init(name: "search_tools", arguments: ["query": .string("read")]))
        let result = await MaestroTools.searchToolsMeta(call)

        XCTAssertTrue(result.contains("read_file"))
    }

    func testSearchToolsScopesToEnabledCategoriesOnly() async {
        MaestroTools.currentIsNavigator = false
        MaestroTools.currentEnabledCategories = [.file] // deliberately no .kanban
        defer { MaestroTools.currentEnabledCategories = nil }

        let call = ToolCall(function: .init(name: "search_tools", arguments: ["query": .string("kanban")]))
        let result = await MaestroTools.searchToolsMeta(call)

        XCTAssertFalse(result.contains("list_kanban_boards"))
    }

    func testSearchToolsBrowseModeListsGroupedCategories() async {
        MaestroTools.currentIsNavigator = false
        MaestroTools.currentEnabledCategories = [.file, .kanban]
        defer { MaestroTools.currentEnabledCategories = nil }

        let call = ToolCall(function: .init(name: "search_tools", arguments: [:]))
        let result = await MaestroTools.searchToolsMeta(call)

        XCTAssertTrue(result.contains("Files"))
        XCTAssertTrue(result.contains("Kanban"))
    }

    func testCallToolDispatchesToUnderlyingTool() async {
        MaestroTools.currentIsNavigator = false
        MaestroTools.currentEnabledCategories = [.kanban]
        defer { MaestroTools.currentEnabledCategories = nil }

        let direct = await MaestroTools.execute(
            ToolCall(function: .init(name: "list_kanban_boards", arguments: [:])))
        let viaMeta = await MaestroTools.callToolMeta(
            ToolCall(function: .init(name: "call_tool", arguments: ["name": .string("list_kanban_boards")])))

        XCTAssertEqual(direct, viaMeta)
    }

    func testCallToolRejectsOutOfScopeCategory() async {
        MaestroTools.currentIsNavigator = false
        MaestroTools.currentEnabledCategories = [.memory] // deliberately excludes .kanban
        defer { MaestroTools.currentEnabledCategories = nil }

        let call = ToolCall(function: .init(name: "call_tool", arguments: ["name": .string("list_kanban_boards")]))
        let result = await MaestroTools.callToolMeta(call)

        XCTAssertTrue(result.contains("error"))
        XCTAssertTrue(result.contains("isn't enabled"))
    }

    func testCallToolRejectsUnknownName() async {
        MaestroTools.currentEnabledCategories = nil
        let call = ToolCall(function: .init(name: "call_tool", arguments: ["name": .string("totally_made_up_tool")]))
        let result = await MaestroTools.callToolMeta(call)

        XCTAssertTrue(result.contains("error"))
    }

    func testCallToolRejectsNonDeferrableTool() async {
        // get_current_time has no ToolCategory at all — call_tool must not
        // become a backdoor around always-on tools that were never hidden.
        MaestroTools.currentEnabledCategories = nil
        let call = ToolCall(function: .init(name: "call_tool", arguments: ["name": .string("get_current_time")]))
        let result = await MaestroTools.callToolMeta(call)

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

    // MARK: - Polymorphic file read/write

    private func tempTestDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMaestroFileTests-\(UUID().uuidString)")
    }

    private func makeCall(name: String, args: [String: JSONValue]) -> ToolCall {
        ToolCall(function: .init(name: name, arguments: args))
    }

    func testReadWriteTextFile() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        let path = dir.appendingPathComponent("test.txt").path
        let write = makeCall(name: "write_file", args: [
            "path": .string(path),
            "content": .string("Hello, SwiftMaestro file tools!")
        ])
        let writeResult = await MaestroTools.execute(write)
        XCTAssertTrue(writeResult.contains("status"))
        XCTAssertTrue(writeResult.contains("written"))

        let read = makeCall(name: "read_file", args: ["path": .string(path)])
        let readResult = await MaestroTools.execute(read)
        XCTAssertTrue(readResult.contains("Hello, SwiftMaestro file tools!"))
    }

    func testWriteAndReadBinaryFile() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        let original = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let base64 = original.base64EncodedString()
        let path = dir.appendingPathComponent("test.bin").path

        let write = makeCall(name: "write_file", args: [
            "path": .string(path),
            "content": .string(base64),
            "encoding": .string("base64")
        ])
        let writeResult = await MaestroTools.execute(write)
        XCTAssertTrue(writeResult.contains("written"))

        let read = makeCall(name: "read_file", args: ["path": .string(path)])
        let readResult = await MaestroTools.execute(read)
        let readJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(readResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(readJSON["type"] as? String, "binary")
        XCTAssertEqual(readJSON["base64"] as? String, base64)
        XCTAssertEqual(readJSON["size_bytes"] as? Int, original.count)

        let roundTrip = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(roundTrip, original)
    }

    func testReadPDFExtractsText() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        let path = dir.appendingPathComponent("test.pdf").path
        let url = URL(fileURLWithPath: path)

        // Create a minimal PDF with real text content using CoreGraphics.
        let text = "Hello from PDF"
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Could not create PDF context")
            return
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attrString = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor.black as Any
            ]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 100, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let read = makeCall(name: "read_file", args: ["path": .string(path)])
        let readResult = await MaestroTools.execute(read)
        XCTAssertTrue(readResult.contains("Hello from PDF"))
    }

    func testReadRTFExtractsText() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        let rtf = "{\\rtf1\\ansi Hello from RTF}"
        let path = dir.appendingPathComponent("test.rtf").path
        try rtf.write(toFile: path, atomically: true, encoding: .ascii)

        let read = makeCall(name: "read_file", args: ["path": .string(path)])
        let readResult = await MaestroTools.execute(read)
        XCTAssertTrue(readResult.contains("Hello from RTF"))
    }

    func testReadBinaryReturnsBase64Metadata() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        let data = Data("not really a png".utf8)
        let path = dir.appendingPathComponent("test.png").path
        try data.write(to: URL(fileURLWithPath: path))

        let read = makeCall(name: "read_file", args: ["path": .string(path)])
        let readResult = await MaestroTools.execute(read)
        let readJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(readResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(readJSON["type"] as? String, "binary")
        XCTAssertEqual(readJSON["mime_type"] as? String, "image/png")
        XCTAssertEqual(readJSON["size_bytes"] as? Int, data.count)
    }

    // MARK: - Document chunk indexing (RAG)

    func testIndexDocumentAndSearchChunks() async throws {
        let dir = tempTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MaestroTools.workingDirectory = dir.path
        defer { MaestroTools.workingDirectory = nil }

        // Write a long document with known repeated phrases.
        let paragraphs = (0..<20).map { i in
            "Paragraph \(i). The quick brown fox jumps over the lazy dog. "
            + (i == 7 ? "SWIFTMAESTRO_UNIQUE_TARGET_PHRASE appears exactly here in paragraph seven. " : "")
            + "More filler text to ensure the document is long enough to chunk properly."
        }
        let docPath = dir.appendingPathComponent("long_doc.txt").path
        try paragraphs.joined(separator: "\n\n").write(toFile: docPath, atomically: true, encoding: .utf8)

        let indexName = "test-rag-" + UUID().uuidString
        let index = makeCall(name: "index_document", args: [
            "paths": .array([.string(docPath)]),
            "index_name": .string(indexName),
            "chunk_words": .int(50),
            "overlap_words": .int(10),
        ])
        let indexResult = await MaestroTools.execute(index)
        let indexJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(indexResult.utf8)) as? [String: Any]
        )
        XCTAssertEqual(indexJSON["status"] as? String, "indexed")
        XCTAssertGreaterThan((indexJSON["total_chunks"] as? Int) ?? 0, 0)

        // Loose fuzzy search should find the unique phrase.
        let search = makeCall(name: "search_chunks", args: [
            "index_name": .string(indexName),
            "query": .string("SWIFTMAESTRO UNIQUE TARGET"),
            "top_k": .int(5),
        ])
        let searchResult = await MaestroTools.execute(search)
        let searchJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(searchResult.utf8)) as? [String: Any]
        )
        let results = try XCTUnwrap(searchJSON["results"] as? [[String: Any]])
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { result in
            ((result["preview"] as? String) ?? "").contains("SWIFTMAESTRO_UNIQUE_TARGET_PHRASE")
        })

        // read_chunk should return the exact full text.
        guard let firstChunkId = results.first?["chunk_id"] as? String else {
            XCTFail("No chunk id returned")
            return
        }
        let readChunk = makeCall(name: "read_chunk", args: [
            "index_name": .string(indexName),
            "chunk_id": .string(firstChunkId),
        ])
        let chunkResult = await MaestroTools.execute(readChunk)
        let chunkJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(chunkResult.utf8)) as? [String: Any]
        )
        let chunkText = try XCTUnwrap(chunkJSON["text"] as? String)
        XCTAssertFalse(chunkText.isEmpty)

        // Cleanup: the index lives under ~/.ai-context/memory/knowledge/indices/
        let home = FileManager.default.homeDirectoryForCurrentUser
        let indexDir = home
            .appendingPathComponent(".ai-context")
            .appendingPathComponent("memory")
            .appendingPathComponent("knowledge")
            .appendingPathComponent("indices")
            .appendingPathComponent(sanitizeForTest(indexName))
        try? FileManager.default.removeItem(at: indexDir)
    }

    private func sanitizeForTest(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    // MARK: - Web search (Bing HTML parser)

    func testParseBingResultsExtractsTitleURLAndSnippet() {
        let html = """
        <ol>
            <li class="b_algo" data-id iid=SERP.5324>
                <div class="b_tpcn"><a href="ignored">top card</a></div>
                <h2 class=""><a target="_blank" href="https://www.bing.com/ck/a?!&&p=e0579fccfd9bfd11d81e65132465e3671301d796822a5d626d89e1a15c8154aeJmltdHM9MTc4NTAyNDAwMA&ptn=3&ver=2&hsh=4&fclid=119c4e63-7dcf-6064-1d26-59c17c5261e8&u=a1aHR0cHM6Ly93d3cuc3dpZnQub3JnL2Jsb2cvc3dpZnQtNi4zLXJlbGVhc2VkLw&ntb=1"><strong>Swift 6.3</strong> Released | Swift.org</a></h2>
                <div class="b_caption"><p class="b_lineclamp2"><span class="news_dt">24 Mar 2026</span>&nbsp;&#0183;&#32;Swift 6.3 makes these benefits more accessible across the stack.</p></div>
            </li>
        </ol>
        """
        let results = MaestroTools.parseBingResults(html, maxResults: 5)
        XCTAssertEqual(results.count, 1)
        let result = results[0]
        XCTAssertEqual(result.title, "Swift 6.3 Released | Swift.org")
        XCTAssertEqual(result.url, "https://www.swift.org/blog/swift-6.3-released/")
        XCTAssertTrue(result.snippet.contains("Swift 6.3 makes these benefits"))
    }

    func testParseBingResultsRespectsMaxResults() {
        let html = """
        <ol>
            <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS8x">One</a></h2></li>
            <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS8y">Two</a></h2></li>
            <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS8z">Three</a></h2></li>
        </ol>
        """
        let results = MaestroTools.parseBingResults(html, maxResults: 2)
        XCTAssertEqual(results.count, 2)
    }
}
