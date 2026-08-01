import XCTest
@testable import SwiftMaestro

final class MCPClientServiceTests: XCTestCase {

    // MARK: - Orphaned subprocess reaping
    //
    // `MCPClientService.shutdown()` only runs on a GRACEFUL app quit (wired
    // to `applicationWillTerminate`). A hard-kill via Xcode's Stop button
    // during development, a force-quit, or a crash bypasses it entirely, so
    // a server whose handshake DID succeed can still leak one orphaned
    // process per such termination - this is exactly how whatsapp-mcp-server
    // accumulated 44+ new orphans (on top of the 189 an earlier fix already
    // cleaned up) over repeated rebuild/relaunch cycles, confirmed live via
    // `ps -eo pid,ppid,...` showing every one of them reparented to launchd
    // (ppid 1). `reapStaleInstances` kills anything matching a server's
    // command line before spawning a fresh instance, so orphans never
    // survive past the next launch instead of accumulating indefinitely.

    func testReapStaleInstancesKillsMatchingOrphanedProcess() throws {
        // Stand in for "a process left over from a previous, uncleanly
        // terminated launch": a long-running process whose argv contains a
        // unique marker so `pgrep -f` can find it without ambiguity. `yes`
        // (not `sleep`) is used because it runs directly - no shell wrapper
        // that could exec() away the marker text before pgrep ever sees it.
        let marker = "swiftmaestro-mcp-reap-test-\(UUID().uuidString)"
        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        dummy.arguments = [marker]
        dummy.standardOutput = FileHandle.nullDevice
        dummy.standardError = FileHandle.nullDevice
        try dummy.run()
        defer { if dummy.isRunning { dummy.terminate() } }  // safety net if an assertion fails first

        // Give the process table a moment to settle before relying on pgrep.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(dummy.isRunning, "the dummy process must be alive before we test reaping it")

        let entry = MCPServerEntry(
            name: "reap-test", command: "/usr/bin/yes", scriptPath: marker,
            env: "", workingDir: "", timeout: 4, enabled: true
        )
        MCPClientService.reapStaleInstances(of: entry)

        // Reaping sends SIGKILL directly by pid, independent of this
        // `Process` object's own bookkeeping, so poll briefly for the OS to
        // reflect the exit rather than asserting immediately.
        let deadline = Date().addingTimeInterval(3)
        while dummy.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(dummy.isRunning, "a process matching the entry's scriptPath must be killed")
    }

    func testReapStaleInstancesLeavesUnrelatedProcessesAlone() throws {
        let unrelatedMarker = "swiftmaestro-mcp-reap-test-unrelated-\(UUID().uuidString)"
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        unrelated.arguments = [unrelatedMarker]
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer { unrelated.terminate() }
        Thread.sleep(forTimeInterval: 0.2)

        // Reap for a DIFFERENT, non-matching marker - the unrelated process
        // must survive.
        let entry = MCPServerEntry(
            name: "reap-test-other", command: "/usr/bin/yes",
            scriptPath: "swiftmaestro-mcp-reap-test-\(UUID().uuidString)-does-not-match-anything",
            env: "", workingDir: "", timeout: 4, enabled: true
        )
        MCPClientService.reapStaleInstances(of: entry)

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(unrelated.isRunning, "a process not matching the entry's scriptPath must be left alone")
    }

    func testReapStaleInstancesIsANoOpForAnEmptyPattern() {
        // Must not attempt to pgrep/kill anything (and must not crash) when
        // an entry has neither a scriptPath nor a workingDir to match on.
        let entry = MCPServerEntry(
            name: "empty-pattern", command: "/usr/bin/yes", scriptPath: "",
            env: "", workingDir: "", timeout: 4, enabled: true
        )
        MCPClientService.reapStaleInstances(of: entry)  // should simply return early
    }

    func testReapStaleInstancesFindsProcessByWorkingDirectoryEvenWithNoMarkerInArgv() throws {
        // Reproduces the exact gap `pgrep -f` alone missed live: `uv run`
        // spawns a detached CPython child visible in `ps` only as a generic
        // "Python main.py" — no server-identifying text anywhere in its
        // argv, only its CURRENT WORKING DIRECTORY reveals which server it
        // belongs to. Confirmed live: killing only the argv-matching `uv`
        // wrapper processes left 45 of these still running as orphans.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        // Deliberately NO distinguishing marker in argv - only cwd ties this
        // process back to the server it belongs to.
        dummy.currentDirectoryURL = tempDir
        dummy.standardOutput = FileHandle.nullDevice
        dummy.standardError = FileHandle.nullDevice
        try dummy.run()
        defer { if dummy.isRunning { dummy.terminate() } }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(dummy.isRunning)

        let entry = MCPServerEntry(
            name: "reap-test-cwd", command: "/usr/bin/yes", scriptPath: "",
            env: "", workingDir: tempDir.path, timeout: 4, enabled: true
        )
        MCPClientService.reapStaleInstances(of: entry)

        let deadline = Date().addingTimeInterval(3)
        while dummy.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(
            dummy.isRunning,
            "a process whose cwd matches the entry's workingDir must be killed even with no argv match"
        )
    }
}
