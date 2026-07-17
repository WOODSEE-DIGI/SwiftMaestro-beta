import XCTest
import MLXLMCommon
import PDFKit
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
        XCTAssertFalse(MaestroTools.handles(""))
    }

    func testHandlesShellTools() {
        XCTAssertTrue(MaestroTools.handles("execute_command"))
        XCTAssertTrue(MaestroTools.handles("list_background_processes"))
        XCTAssertTrue(MaestroTools.handles("stop_background_process"))
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
        XCTAssertTrue(names.contains("list_canvas_boards"))
        XCTAssertTrue(names.contains("list_numbers_documents"))
        XCTAssertTrue(names.contains("read_numbers_table"))
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
}
