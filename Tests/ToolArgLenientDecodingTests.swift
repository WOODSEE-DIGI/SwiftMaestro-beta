import XCTest
import MLXLMCommon
@testable import SwiftMaestro

/// Regression tests for the glob_files / write_file argument-decode failures
/// the agent hit while editing Xcode projects: small models (Gemma 4) emit
/// numbers and booleans as STRINGS ("200", "false"), and the strict Int?/Bool?
/// fields failed the WHOLE struct decode — the tool then reported a
/// misleading "requires 'pattern'" / "requires 'path' and 'content'" error
/// even though those arguments were present.
@MainActor
final class ToolArgLenientDecodingTests: XCTestCase {

    private func call(_ name: String, _ arguments: [String: JSONValue]) -> ToolCall {
        ToolCall(function: .init(name: name, arguments: arguments))
    }

    // MARK: - glob_files

    func testGlobFilesArgsDecodesStringLimit() {
        let args = MaestroTools.decodeArgs(call("glob_files", [
            "pattern": .string("**/*.swift"),
            "limit": .string("200"),
        ]), as: MaestroTools.GlobFilesArgs.self)
        XCTAssertEqual(args?.pattern, "**/*.swift")
        XCTAssertEqual(args?.limit?.value, 200)
    }

    func testGlobFilesArgsDecodesMangledLimit() {
        let args = MaestroTools.decodeArgs(call("glob_files", [
            "pattern": .string("*.swift"),
            "limit": .string("\"50}\""),
        ]), as: MaestroTools.GlobFilesArgs.self)
        XCTAssertEqual(args?.limit?.value, 50)
    }

    func testGlobFilesArgsDecodesProperTypes() {
        let args = MaestroTools.decodeArgs(call("glob_files", [
            "pattern": .string("*.swift"),
            "limit": .int(25),
        ]), as: MaestroTools.GlobFilesArgs.self)
        XCTAssertEqual(args?.limit?.value, 25)
    }

    // MARK: - grep_code

    func testGrepCodeArgsDecodesStringBoolAndLimit() {
        let args = MaestroTools.decodeArgs(call("grep_code", [
            "pattern": .string("detect"),
            "case_sensitive": .string("false"),
            "limit": .string("500"),
        ]), as: MaestroTools.GrepCodeArgs.self)
        XCTAssertEqual(args?.pattern, "detect")
        XCTAssertEqual(args?.case_sensitive?.value, false)
        XCTAssertEqual(args?.limit?.value, 500)
    }

    // MARK: - edit_file

    func testEditFileArgsDecodesStringReplaceAll() {
        let args = MaestroTools.decodeArgs(call("edit_file", [
            "path": .string("/tmp/x.swift"),
            "old_string": .string("a"),
            "new_string": .string("b"),
            "replace_all": .string("true"),
        ]), as: MaestroTools.EditFileArgs.self)
        XCTAssertEqual(args?.replace_all?.value, true)
    }

    // MARK: - write_file

    func testWriteFileArgsDecodesStringAppend() {
        let args = MaestroTools.decodeArgs(call("write_file", [
            "path": .string("/tmp/x.md"),
            "content": .string("hello"),
            "append": .string("false"),
        ]), as: MaestroTools.WriteFileArgs.self)
        XCTAssertEqual(args?.path, "/tmp/x.md")
        XCTAssertEqual(args?.content, "hello")
        XCTAssertEqual(args?.append?.value, false)
    }

    func testWriteFileArgsDecodesBoolAppend() {
        let args = MaestroTools.decodeArgs(call("write_file", [
            "path": .string("/tmp/x.md"),
            "content": .string("hello"),
            "append": .bool(true),
        ]), as: MaestroTools.WriteFileArgs.self)
        XCTAssertEqual(args?.append?.value, true)
    }

    // MARK: - read_file

    func testReadFileArgsDecodesStringOffsetAndLimit() {
        let args = MaestroTools.decodeArgs(call("read_file", [
            "path": .string("/tmp/x.md"),
            "offset": .string("10"),
            "limit": .string("40"),
        ]), as: MaestroTools.ReadFileArgs.self)
        XCTAssertEqual(args?.offset?.value, 10)
        XCTAssertEqual(args?.limit?.value, 40)
    }

    // MARK: - git_log

    func testGitLogArgsDecodesStringLimit() {
        let args = MaestroTools.decodeArgs(call("git_log", [
            "path": .string("/tmp"),
            "limit": .string("25"),
        ]), as: MaestroTools.GitLogArgs.self)
        XCTAssertEqual(args?.limit?.value, 25)
    }

    // MARK: - argDiagnostics

    func testArgDiagnosticsListsKeysAndTypes() {
        let diagnostics = MaestroTools.argDiagnostics(call("write_file", [
            "path": .string("/tmp/x"),
            "append": .string("false"),
            "count": .int(3),
        ]))
        XCTAssertTrue(diagnostics.contains("path:string"), diagnostics)
        XCTAssertTrue(diagnostics.contains("append:string"), diagnostics)
        XCTAssertTrue(diagnostics.contains("count:number"), diagnostics)
        // String VALUES are never leaked into diagnostics.
        XCTAssertFalse(diagnostics.contains("/tmp/x"), diagnostics)
        XCTAssertFalse(diagnostics.contains("false]"), diagnostics)
    }

    func testArgDiagnosticsWithNoArguments() {
        XCTAssertEqual(MaestroTools.argDiagnostics(call("glob_files", [:])), "no arguments received")
    }

    // MARK: - normalizeGlobPattern (the zero-match glob loop)
    //
    // The model mimicked JSON escaping and sent "**\\/*.swift" — it matched
    // nothing, three times in a row, because nothing normalized it.

    func testGlobPatternBackslashSlashIsCollapsed() {
        XCTAssertEqual(MaestroTools.normalizeGlobPattern("**\\/*.swift"), "**/*.swift")
        XCTAssertEqual(MaestroTools.normalizeGlobPattern("Sources\\/Engine\\/*.swift"), "Sources/Engine/*.swift")
    }

    func testGlobPatternQuotedIsUnwrapped() {
        XCTAssertEqual(MaestroTools.normalizeGlobPattern("\"**/*.swift\""), "**/*.swift")
    }

    func testGlobPatternPlainIsUntouched() {
        XCTAssertEqual(MaestroTools.normalizeGlobPattern("**/*.swift"), "**/*.swift")
        XCTAssertEqual(MaestroTools.normalizeGlobPattern("*.md"), "*.md")
    }
}

extension ToolArgLenientDecodingTests {
    // MARK: - unescapeShellPath backslash runs (read_file "no file at" /
    // write_file "volume is read only" were over-escaped separators, not I/O)

    func testUnescapeShellPathCollapsesAllSeparatorRuns() {
        XCTAssertEqual(MaestroTools.unescapeShellPath(#"\/Users\/testuser"#), "/Users/testuser")
        XCTAssertEqual(MaestroTools.unescapeShellPath(#"\/Users\\\/testuser"#), "/Users/testuser")
        XCTAssertEqual(MaestroTools.unescapeShellPath(#"\/Users\\\\\/testuser"#), "/Users/testuser")
    }

    func testUnescapeShellPathKeepsShellSpaceEscapes() {
        XCTAssertEqual(MaestroTools.unescapeShellPath(#"2\ AREAS"#), "2 AREAS")
        XCTAssertEqual(MaestroTools.unescapeShellPath(#"O\ Hara"#), "O Hara")
    }

    func testUnescapeShellPathPlainIsUntouched() {
        XCTAssertEqual(MaestroTools.unescapeShellPath("/Users/testuser/GitHub"), "/Users/testuser/GitHub")
    }
}
