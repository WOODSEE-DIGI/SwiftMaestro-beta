import SwiftUI

// MARK: - Reminders view

/// Native Apple Reminders reader with a minimal form to add new reminders.
struct RemindersView: View {
    @Environment(EventKitStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    @State private var newTitle = ""
    @State private var newDue = Date()
    @State private var hasDue = false
    @State private var newNotes = ""
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            if let error = store.remindersError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
            }

            if isAdding {
                newReminderForm
                    .padding()
            }

            List {
                ForEach(groupedReminders, id: \.key) { section in
                    Section(header: Text(section.key)) {
                        ForEach(section.reminders) { reminder in
                            reminderRow(reminder)
                        }
                    }
                }
            }
        }
        .task {
            await store.loadReminders()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Reminders")
                .font(.headline)
            Spacer()
            Button {
                isAdding.toggle()
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                Task { await store.loadReminders() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Reminder row

    private func reminderRow(_ reminder: MacOSIntegration.ReminderItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(reminder.isCompleted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .strikethrough(reminder.isCompleted)
                HStack(spacing: 6) {
                    if let due = reminder.dueDate {
                        Text(dueString(due))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(reminder.listTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - New reminder form

    private var newReminderForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Reminder")
                .font(.headline)
            TextField("Title", text: $newTitle)
            Toggle("Due date", isOn: $hasDue)
            if hasDue {
                DatePicker("Due", selection: $newDue)
            }
            TextField("Notes", text: $newNotes)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAdding = false }
                Button("Create") {
                    Task { await createReminder() }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .background(theme.secondaryBackground)
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private var groupedReminders: [(key: String, reminders: [MacOSIntegration.ReminderItem])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let grouped = Dictionary(grouping: store.reminders) { reminder in
            reminder.dueDate.map { formatter.string(from: $0) } ?? "No due date"
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, reminders: $0.value.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) }
    }

    private func dueString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func createReminder() async {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await store.createReminder(
                title: newTitle.trimmingCharacters(in: .whitespaces),
                due: hasDue ? newDue : nil,
                notes: newNotes.isEmpty ? nil : newNotes
            )
            newTitle = ""
            newNotes = ""
            hasDue = false
            isAdding = false
        } catch {
            store.remindersError = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    RemindersView()
        .environment(EventKitStore())
        .environment(ThemeStore())
}
