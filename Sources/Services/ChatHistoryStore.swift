import Foundation

/// Persists each agent's chat history (the conversation) separately from project
/// memory. Clearing a chat removes only this file — the project's ai-context
/// memory is never touched. History survives app restarts.
///
/// Persistence note: every operation logs failures with a `[PERSIST]` prefix so
/// a broken store can never again fail silently (previously all errors were
/// swallowed by `try?`, which hid a multi-week persistence outage).
enum ChatHistoryStore {
    private static func chatsDir() -> URL {
        let dir = WorkspaceStore.dataDir().appendingPathComponent("chats", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[PERSIST] chats dir create failed at \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }

    private static func fileURL(agentId: UUID) -> URL {
        chatsDir().appendingPathComponent("\(agentId.uuidString).json")
    }

    static func load(agentId: UUID) -> [Message]? {
        let url = fileURL(agentId: agentId)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A missing file is normal for a fresh/cleared agent — not an error.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                NSLog("[PERSIST] chat READ failed for \(agentId.uuidString): \(error.localizedDescription)")
            }
            return nil
        }
        do {
            return try JSONDecoder().decode([Message].self, from: data)
        } catch {
            NSLog("[PERSIST] chat DECODE failed for \(agentId.uuidString) (\(data.count) bytes at \(url.path)): \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ messages: [Message], agentId: UUID) {
        let data: Data
        do {
            data = try JSONEncoder().encode(messages)
        } catch {
            NSLog("[PERSIST] chat ENCODE failed for \(agentId.uuidString) (\(messages.count) messages): \(error.localizedDescription)")
            return
        }
        do {
            try data.write(to: fileURL(agentId: agentId), options: .atomic)
        } catch {
            NSLog("[PERSIST] chat WRITE failed for \(agentId.uuidString): \(error.localizedDescription)")
        }
    }

    static func clear(agentId: UUID) {
        do {
            try FileManager.default.removeItem(at: fileURL(agentId: agentId))
        } catch {
            // Clearing an agent with no persisted history is normal — not an error.
            if (error as NSError).code != NSFileNoSuchFileError {
                NSLog("[PERSIST] chat CLEAR failed for \(agentId.uuidString): \(error.localizedDescription)")
            }
        }
    }
}
