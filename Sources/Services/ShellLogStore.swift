import Foundation
import SwiftUI

// MARK: - Shell Log Entry

/// A single shell execution log entry.
public struct ShellLogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let command: String
    public let cwd: String
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var durationMs: Int
    public var timedOut: Bool
    public var completed: Bool

    /// Whether the command succeeded (exit code 0).
    public var success: Bool { exitCode == 0 && !timedOut }

    /// Status icon name.
    public var statusIcon: String {
        if !completed { return "arrow.triangle.2.circlepath" }
        if timedOut { return "exclamationmark.triangle" }
        return success ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    /// Status color.
    public var statusColor: Color {
        if !completed { return .orange }
        if timedOut { return .yellow }
        return success ? .green : .red
    }
}

// MARK: - Shell Log Store

/// Shared store for shell execution log entries.
@MainActor
public final class ShellLogStore: ObservableObject {

    public static let shared = ShellLogStore()

    /// Maximum number of entries to keep in memory.
    public static let maxEntries = 200

    /// All log entries (newest last).
    @Published public var entries: [ShellLogEntry] = []

    /// Whether the terminal panel is visible.
    @Published public var isVisible: Bool = false

    /// Add a new entry (called before execution starts).
    @discardableResult
    public func addEntry(command: String, cwd: String) -> UUID {
        let entry = ShellLogEntry(
            timestamp: Date(),
            command: command,
            cwd: cwd,
            stdout: "",
            stderr: "",
            exitCode: -1,
            durationMs: 0,
            timedOut: false,
            completed: false
        )
        entries.append(entry)
        trimIfNeeded()
        return entry.id
    }

    /// Update an entry with results (called after execution completes).
    public func completeEntry(
        id: UUID,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationMs: Int,
        timedOut: Bool
    ) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].stdout = stdout
        entries[idx].stderr = stderr
        entries[idx].exitCode = exitCode
        entries[idx].durationMs = durationMs
        entries[idx].timedOut = timedOut
        entries[idx].completed = true
    }

    /// Clear all entries.
    public func clear() {
        entries.removeAll()
    }

    private func trimIfNeeded() {
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
