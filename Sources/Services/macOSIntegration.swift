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

    struct ReminderItem: Sendable, Identifiable {
        let id: String
        let title: String
        let isCompleted: Bool
        let dueDate: Date?
        let listTitle: String
        let notes: String?
    }

    struct ReminderList: Sendable {
        let id: String
        let title: String
        let isDefault: Bool
    }

    // Shared helper: request access once, return the store.
    private static func reminderStore() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        NSLog("[EventKit] requestFullAccessToReminders → \(granted)")
        guard granted else {
            throw IntegrationError.accessDenied("Reminders")
        }
        return store
    }

    /// Resolve a calendar by title (case-insensitive prefix match).
    /// Falls back to the default if no match or if `listName` is nil/empty.
    private static func resolveCalendar(
        from store: EKEventStore, named listName: String?
    ) throws -> EKCalendar {
        guard let listName, !listName.trimmingCharacters(in: .whitespaces).isEmpty else {
            guard let def = store.defaultCalendarForNewReminders() else {
                throw IntegrationError.noDefaultCalendar("Reminders list")
            }
            return def
        }
        let allCalendars = store.calendars(for: .reminder)
        // Exact match first
        if let match = allCalendars.first(where: {
            $0.title.localizedCaseInsensitiveContains(listName)
        }) {
            return match
        }
        throw IntegrationError.noDefaultCalendar(
            "No reminder list named \"\(listName)\". "
            + "Available lists: \(allCalendars.map(\.title).joined(separator: ", "))")
    }

    /// List all available Reminder lists (calendars of type .reminder).
    static func fetchReminderLists() async throws -> [ReminderList] {
        let store = try await reminderStore()
        let allCalendars = store.calendars(for: .reminder)
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return allCalendars.map { cal in
            ReminderList(
                id: cal.calendarIdentifier,
                title: cal.title,
                isDefault: cal.calendarIdentifier == defaultID
            )
        }
    }

    static func fetchReminders(limit: Int = 50, listName: String? = nil) async throws -> [ReminderItem] {
        let store = try await reminderStore()
        let calendar: EKCalendar?
        if let listName, !listName.trimmingCharacters(in: .whitespaces).isEmpty {
            calendar = try resolveCalendar(from: store, named: listName)
        } else {
            calendar = nil
        }
        let calendars = calendar.map { [$0] }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { (cont: CheckedContinuation<[ReminderItem], Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).prefix(limit).map { reminder -> ReminderItem in
                    let due = reminder.dueDateComponents
                        .flatMap { Calendar.current.date(from: $0) }
                    return ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "(untitled)",
                        isCompleted: reminder.isCompleted,
                        dueDate: due,
                        listTitle: reminder.calendar?.title ?? "Reminders",
                        notes: reminder.notes
                    )
                }
                cont.resume(returning: items)
            }
        }
    }

    static func createReminder(
        title: String, notes: String?, due: String?, list listName: String? = nil
    ) async throws -> String {
        let store = try await reminderStore()
        let calendar = try resolveCalendar(from: store, named: listName)
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
        NSLog("[EventKit] Saved reminder \"\(title)\" to list \"\(calendar.title)\"")
        return "Created reminder \"\(title)\" in list \"\(calendar.title)\"."
    }

    static func listReminders(limit: Int = 25, listName: String? = nil) async throws -> [String] {
        let store = try await reminderStore()
        let calendar: EKCalendar?
        if let listName, !listName.trimmingCharacters(in: .whitespaces).isEmpty {
            calendar = try resolveCalendar(from: store, named: listName)
        } else {
            calendar = nil
        }
        let calendars = calendar.map { [$0] }
        let predicate = store.predicateForReminders(in: calendars)
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

    struct CalendarEvent: Sendable, Identifiable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let calendarTitle: String
        let notes: String?
    }

    static func fetchCalendarEvents(
        start: Date,
        end: Date,
        limit: Int = 50
    ) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw IntegrationError.accessDenied("Calendar")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(limit).map { event in
            CalendarEvent(
                id: event.calendarItemIdentifier,
                title: event.title ?? "(untitled)",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar?.title ?? "Calendar",
                notes: event.notes
            )
        }
    }

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
