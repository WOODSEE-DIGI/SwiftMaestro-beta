import Foundation
import MLXLMCommon

// MARK: - Native macOS system tools
//
// Expose the real `MacOSIntegration` (EventKit Reminders/Calendar, Notes via
// Apple Events, URL opening) as in-process agent tools. Each reports the actual
// outcome; permission prompts appear on first use.
extension MaestroTools {

    static let systemToolNames: Set<String> = [
        "create_reminder", "list_reminders", "create_calendar_event",
        "create_note", "open_url",
    ]

    static var systemToolSpecs: [ToolSpec] {
        [
            rawSpec("create_reminder",
                "Create a reminder in the macOS Reminders app. Prompts for access on first use.",
                properties: [
                    "title": ["type": "string", "description": "Reminder title."],
                    "notes": ["type": "string", "description": "Optional notes."],
                    "due": ["type": "string", "description": "Optional ISO-8601 due date/time, e.g. 2026-06-15T14:00:00Z."],
                ], required: ["title"]),
            rawSpec("list_reminders",
                "List reminders from the macOS Reminders app.",
                properties: [
                    "limit": ["type": "integer", "description": "Max reminders to return (default 25)."],
                ], required: []),
            rawSpec("create_calendar_event",
                "Create an event in the macOS Calendar app. Prompts for access on first use.",
                properties: [
                    "title": ["type": "string", "description": "Event title."],
                    "start": ["type": "string", "description": "ISO-8601 start, e.g. 2026-06-15T14:00:00Z."],
                    "end": ["type": "string", "description": "ISO-8601 end."],
                    "notes": ["type": "string", "description": "Optional notes."],
                ], required: ["title", "start", "end"]),
            rawSpec("create_note",
                "Create a note in the macOS Notes app.",
                properties: [
                    "title": ["type": "string", "description": "Note title."],
                    "body": ["type": "string", "description": "Note body text."],
                ], required: ["title", "body"]),
            rawSpec("open_url",
                "Open a URL in the user's default browser.",
                properties: [
                    "url": ["type": "string", "description": "The URL to open (https://…)."],
                ], required: ["url"]),
        ]
    }

    private struct ReminderArgs: Codable { let title: String?; let notes: String?; let due: String? }
    private struct ListRemindersArgs: Codable { let limit: Int? }
    private struct EventArgs: Codable { let title: String?; let start: String?; let end: String?; let notes: String? }
    private struct NoteArgs: Codable { let title: String?; let body: String? }
    private struct OpenURLArgs: Codable { let url: String? }

    static func createReminder(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: ReminderArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return errorJSON("create_reminder requires 'title'")
        }
        do { return try await MacOSIntegration.createReminder(title: title, notes: a.notes, due: a.due) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func listRemindersTool(_ call: ToolCall) async -> String {
        let a = decodeArgs(call, as: ListRemindersArgs.self)
        do {
            let items = try await MacOSIntegration.listReminders(limit: a?.limit ?? 25)
            return items.isEmpty
                ? "No reminders found."
                : "Reminders (\(items.count)):\n" + items.joined(separator: "\n")
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func createCalendarEvent(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: EventArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let start = a.start, let end = a.end else {
            return errorJSON("create_calendar_event requires 'title', 'start', and 'end'")
        }
        do { return try await MacOSIntegration.createCalendarEvent(title: title, start: start, end: end, notes: a.notes) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func createNoteTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: NoteArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let body = a.body else {
            return errorJSON("create_note requires 'title' and 'body'")
        }
        do { return try await MacOSIntegration.createNote(title: title, body: body) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func openURLTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: OpenURLArgs.self),
              let url = a.url?.trimmingCharacters(in: .whitespaces), !url.isEmpty else {
            return errorJSON("open_url requires 'url'")
        }
        let ok = await MacOSIntegration.openURL(url)
        return ok ? jsonString(["status": "opened", "url": url]) : errorJSON("could not open '\(url)'")
    }
}
