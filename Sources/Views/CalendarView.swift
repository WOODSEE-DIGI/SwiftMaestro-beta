import SwiftUI

// MARK: - Calendar view

/// Native Apple Calendar reader. Shows upcoming events and a minimal form to add
/// a new event.
struct CalendarView: View {
    @Environment(EventKitStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    @State private var newTitle = ""
    @State private var newStart = Date()
    @State private var newDuration = 60.0
    @State private var newNotes = ""
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            if let error = store.calendarError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
            }

            if isAdding {
                newEventForm
                    .padding()
            }

            List {
                ForEach(groupedEvents, id: \.key) { section in
                    Section(header: Text(section.key)) {
                        ForEach(section.events) { event in
                            eventRow(event)
                        }
                    }
                }
            }
        }
        .task {
            await store.loadCalendarEvents()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Calendar")
                .font(.headline)
            Spacer()
            Button {
                isAdding.toggle()
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                Task { await store.loadCalendarEvents() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Event row

    private func eventRow(_ event: MacOSIntegration.CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(timeRange(for: event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(event.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - New event form

    private var newEventForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Event")
                .font(.headline)
            TextField("Title", text: $newTitle)
            DatePicker("Start", selection: $newStart)
            HStack {
                Text("Duration")
                Slider(value: $newDuration, in: 15...240, step: 15)
                Text("\(Int(newDuration)) min")
                    .monospacedDigit()
            }
            TextField("Notes", text: $newNotes)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAdding = false }
                Button("Create") {
                    Task { await createEvent() }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .background(theme.secondaryBackground)
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private var groupedEvents: [(key: String, events: [MacOSIntegration.CalendarEvent])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let grouped = Dictionary(grouping: store.calendarEvents) { formatter.string(from: $0.startDate) }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, events: $0.value.sorted { $0.startDate < $1.startDate }) }
    }

    private func timeRange(for event: MacOSIntegration.CalendarEvent) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        if event.isAllDay {
            return "All day"
        }
        return "\(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))"
    }

    private func createEvent() async {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let end = newStart.addingTimeInterval(newDuration * 60)
        do {
            try await store.createEvent(
                title: newTitle.trimmingCharacters(in: .whitespaces),
                start: newStart,
                end: end,
                notes: newNotes.isEmpty ? nil : newNotes
            )
            newTitle = ""
            newNotes = ""
            isAdding = false
        } catch {
            store.calendarError = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    CalendarView()
        .environment(EventKitStore())
        .environment(ThemeStore())
}
