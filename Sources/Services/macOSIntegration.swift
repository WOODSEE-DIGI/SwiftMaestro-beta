import Foundation
import EventKit
import AppKit

/// Real macOS system integration: Reminders + Calendar via EventKit, Notes via
/// Apple Events, and URL opening via NSWorkspace. Every call reports actual
/// success/failure (no stubbed `true`). Permission prompts appear on first use;
/// the usage strings live in Info.plist and the apple-events entitlement is set.
enum MacOSIntegration {

    enum IntegrationError: LocalizedError {
        case accessDenied(String)
        case noDefaultCalendar(String)
        case badDate(String)
        case appleScript(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let what):
                return "Access to \(what) was denied. Grant it in System Settings → Privacy & Security."
            case .noDefaultCalendar(let what):
                return "No default \(what) is configured in the Calendar/Reminders app."
            case .badDate(let s):
                return "Could not parse the date \"\(s)\". Use ISO-8601, e.g. 2026-06-15T14:00:00Z."
            case .appleScript(let msg):
                return "Notes scripting failed: \(msg)"
            }
        }
    }

    // MARK: - Reminders

    static func createReminder(title: String, notes: String?, due: String?) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw IntegrationError.accessDenied("Reminders")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw IntegrationError.noDefaultCalendar("Reminders list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        if let due, !due.trimmingCharacters(in: .whitespaces).isEmpty {
            let date = try parseDate(due)
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
        try store.save(reminder, commit: true)
        return "Created reminder \"\(title)\" in \(calendar.title)."
    }

    static func listReminders(limit: Int = 25) async throws -> [String] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw IntegrationError.accessDenied("Reminders")
        }
        let predicate = store.predicateForReminders(in: nil)
        // Map to plain strings INSIDE the completion so only a Sendable [String]
        // crosses the continuation (EKReminder is not Sendable).
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                let fmt = DateFormatter()
                fmt.dateStyle = .medium; fmt.timeStyle = .short
                let out = (reminders ?? []).prefix(limit).map { r -> String in
                    let status = r.isCompleted ? "[x]" : "[ ]"
                    let due = r.dueDateComponents
                        .flatMap { Calendar.current.date(from: $0) }
                        .map { " (due \(fmt.string(from: $0)))" } ?? ""
                    return "\(status) \(r.title ?? "(untitled)")\(due)"
                }
                cont.resume(returning: out)
            }
        }
    }

    // MARK: - Calendar

    static func createCalendarEvent(title: String, start: String, end: String, notes: String?) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw IntegrationError.accessDenied("Calendar")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw IntegrationError.noDefaultCalendar("calendar")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = try parseDate(start)
        event.endDate = try parseDate(end)
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return "Created event \"\(title)\" on \(formatted(event.startDate))."
    }

    // MARK: - Notes (Apple Events)

    @MainActor
    static func createNote(title: String, body: String) throws -> String {
        let source = """
        tell application "Notes"
            make new note with properties {name:"\(appleScriptEscape(title))", body:"\(appleScriptEscape(body))"}
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw IntegrationError.appleScript("could not compile the script")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            throw IntegrationError.appleScript(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }
        return "Created note \"\(title)\" in Notes."
    }

    // MARK: - URL

    @MainActor
    static func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    /// A fresh formatter per call — avoids a shared non-Sendable static under
    /// Swift strict concurrency.
    private static func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private static func parseDate(_ s: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = plain.date(from: s) { return d }
        plain.dateFormat = "yyyy-MM-dd"
        if let d = plain.date(from: s) { return d }
        // Natural language: "tomorrow at 3pm", "next Monday at 10:30am", etc.
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        let now = Date()
        var date = now
        if lower.contains("tomorrow") {
            date = cal.date(byAdding: .day, value: 1, to: now) ?? now
        } else if lower.contains("today") {
            date = now
        } else if lower.contains("next week") {
            date = cal.date(byAdding: .weekOfYear, value: 1, to: now) ?? now
        }
        // Try to extract time: "at 3pm", "at 15:00", "at 3:30pm"
        let timePattern = /at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/
        if let match = lower.firstMatch(of: timePattern) {
            var hour = Int(match.1) ?? 12
            let minute = Int(match.2 ?? "0") ?? 0
            if let meridian = match.3 {
                if meridian == "pm" && hour < 12 { hour += 12 }
                if meridian == "am" && hour == 12 { hour = 0 }
            }
            date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        guard date != now else { throw IntegrationError.badDate(s) }
        return date
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
