import Foundation
import EventKit
import SwiftUI

// MARK: - EventKit store

/// Shared observable state for Calendar and Reminders integration.
/// Reads and writes through `MacOSIntegration` so the agent tools and the UI
/// use the same path.
@Observable
@MainActor
final class EventKitStore {

    enum AccessStatus: Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    private(set) var calendarStatus: AccessStatus = .notDetermined
    private(set) var remindersStatus: AccessStatus = .notDetermined

    private(set) var calendarEvents: [MacOSIntegration.CalendarEvent] = []
    private(set) var reminders: [MacOSIntegration.ReminderItem] = []
    private(set) var reminderLists: [MacOSIntegration.ReminderList] = []

    var calendarError: String?
    var remindersError: String?

    private let eventStore = EKEventStore()

    // MARK: - Authorization

    func refreshAuthorization() {
        calendarStatus = mapStatus(EKEventStore.authorizationStatus(for: .event))
        remindersStatus = mapStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestCalendarAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            calendarStatus = granted ? .granted : .denied
        } catch {
            calendarStatus = .denied
            calendarError = "Calendar access request failed: \(error.localizedDescription)"
        }
    }

    func requestRemindersAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            remindersStatus = granted ? .granted : .denied
        } catch {
            remindersStatus = .denied
            remindersError = "Reminders access request failed: \(error.localizedDescription)"
        }
    }

    private func mapStatus(_ status: EKAuthorizationStatus) -> AccessStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess, .writeOnly, .authorized:
            // .authorized is deprecated but still returned on some paths.
            return .granted
        @unknown default: return .denied
        }
    }

    // MARK: - Fetch

    func loadCalendarEvents(days: Int = 7, limit: Int = 50) async {
        calendarError = nil
        refreshAuthorization()
        if calendarStatus == .notDetermined {
            await requestCalendarAccess()
        }
        guard calendarStatus == .granted else { return }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        do {
            calendarEvents = try await MacOSIntegration.fetchCalendarEvents(
                start: now, end: end, limit: limit)
        } catch {
            calendarError = error.localizedDescription
        }
    }

    func loadReminders(limit: Int = 50, listName: String? = nil) async {
        remindersError = nil
        refreshAuthorization()
        if remindersStatus == .notDetermined {
            await requestRemindersAccess()
        }
        guard remindersStatus == .granted else { return }

        do {
            reminders = try await MacOSIntegration.fetchReminders(limit: limit, listName: listName)
        } catch {
            remindersError = error.localizedDescription
        }
    }

    func loadReminderLists() async {
        remindersError = nil
        refreshAuthorization()
        if remindersStatus == .notDetermined {
            await requestRemindersAccess()
        }
        guard remindersStatus == .granted else { return }

        do {
            reminderLists = try await MacOSIntegration.fetchReminderLists()
        } catch {
            remindersError = error.localizedDescription
        }
    }

    // MARK: - Create

    func createEvent(title: String, start: Date, end: Date, notes: String?) async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        _ = try await MacOSIntegration.createCalendarEvent(
            title: title,
            start: iso.string(from: start),
            end: iso.string(from: end),
            notes: notes
        )
        await loadCalendarEvents()
    }

    func createReminder(title: String, due: Date?, notes: String?, list: String? = nil) async throws {
        let dueString = due.map { ISO8601DateFormatter().string(from: $0) }
        _ = try await MacOSIntegration.createReminder(
            title: title,
            notes: notes,
            due: dueString,
            list: list
        )
        await loadReminders(listName: list)
    }
}
