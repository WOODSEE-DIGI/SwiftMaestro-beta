import SwiftUI

// MARK: - Reminders Page

/// Shows scheduled invoice reminders and lets the user send due ones.
struct RemindersPage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(viewModel.reminders) { reminder in
                ReminderRow(reminder: reminder, viewModel: viewModel, theme: theme)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chatBackground)
        }
    }

    private var header: some View {
        HStack {
            Text("Invoice Reminders")
                .font(.headline)
            Spacer()
            Button {
                Task { await viewModel.sendDueReminders() }
            } label: {
                Label("Send Due", systemImage: "paperplane")
            }
            .disabled(viewModel.reminders.filter { $0.status == .pending && $0.scheduledDate <= Date() }.isEmpty)
        }
        .padding()
        .background(theme.secondaryBackground)
    }
}

private struct ReminderRow: View {
    let reminder: BooksInvoiceReminder
    @Bindable var viewModel: BooksViewModel
    let theme: ThemeStore

    private var invoice: BooksInvoice? {
        viewModel.invoices.first { $0.id == reminder.invoiceID }
    }

    private var clientName: String {
        guard let invoice else { return "—" }
        return viewModel.clients.first { $0.id == invoice.clientID }?.name ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(reminder.kind.rawValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.chatText)
                Spacer()
                StatusBadge(status: reminder.status)
            }
            HStack(spacing: 12) {
                Text(invoice?.number ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(clientName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Scheduled \(reminder.scheduledDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !reminder.subject.isEmpty {
                Text(reminder.subject)
                    .font(.caption)
                    .foregroundStyle(theme.chatText)
                    .lineLimit(1)
            }
            HStack {
                Spacer()
                if reminder.status == .pending {
                    Button {
                        Task { await viewModel.sendReminder(reminder.id ?? 0) }
                    } label: {
                        Label("Send Now", systemImage: "paperplane")
                    }
                    .disabled(reminder.scheduledDate > Date())
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct StatusBadge: View {
    let status: BooksInvoiceReminder.Status

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: return .orange
        case .sent: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}
