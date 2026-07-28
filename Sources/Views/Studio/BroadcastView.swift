import SwiftUI

struct BroadcastView: View {
    @StateObject private var service = BroadcastService.shared
    @State private var isEditing = false

    private var selectedSession: BroadcastSession? {
        service.selectedSessionID.flatMap { id in service.sessions.first(where: { $0.id == id }) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $service.selectedSessionID) {
                ForEach(service.sessions) { session in
                    sessionRow(session)
                        .tag(session.id)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        service.removeSession(id: service.sessions[index].id)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Broadcast")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let newSession = BroadcastSession.default()
                        service.addSession(newSession)
                        service.selectedSessionID = newSession.id
                        isEditing = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let session = selectedSession {
                detailView(for: session)
            } else {
                ContentUnavailableView(
                    "Select a Destination",
                    systemImage: "arrow.up.circle",
                    description: Text("Choose a broadcast destination to view controls and logs.")
                )
            }
        }
        .sheet(isPresented: $isEditing) {
            if let session = selectedSession {
                BroadcastSessionEditorView(session: session, onSave: { updated in
                    service.updateSession(updated)
                    service.selectedSessionID = updated.id
                })
            }
        }
    }

    private func sessionRow(_ session: BroadcastSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.headline)
                Text(service.snapshots[session.id]?.status.rawValue ?? "Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = service.snapshots[session.id], snapshot.status == .live {
                Button {
                    service.stop(sessionID: session.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    service.start(sessionID: session.id)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(!session.isEnabled)
            }
            Button {
                service.selectedSessionID = session.id
                isEditing = true
            } label: {
                Image(systemName: "pencil")
            }
        }
        .padding(.vertical, 4)
    }

    private func detailView(for session: BroadcastSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.headline)
                    Text(session.outputURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Input: \(session.inputURL)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = service.snapshots[session.id] {
                    Text(snapshot.status.rawValue)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor(snapshot.status).opacity(0.2))
                        .foregroundStyle(statusColor(snapshot.status))
                        .cornerRadius(6)
                    if let pid = snapshot.pid {
                        Text("PID \(pid)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    service.clearLogs(sessionID: session.id)
                } label: {
                    Image(systemName: "clear")
                }
                .help("Clear logs")

                Button {
                    service.removeSession(id: session.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Delete destination")
            }
            .padding()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(service.snapshots[session.id]?.logs ?? [], id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(logColor(line))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.2))
        }
    }

    private func statusColor(_ status: BroadcastStatus) -> Color {
        switch status {
        case .idle: return .secondary
        case .starting: return .orange
        case .live: return .red
        case .stopped: return .secondary
        case .error: return .red
        }
    }

    private func logColor(_ line: String) -> Color {
        if line.lowercased().contains("error") { return .red }
        if line.lowercased().contains("warning") { return .yellow }
        if line.hasPrefix("[info]") { return .cyan }
        return .primary
    }
}

#Preview {
    BroadcastView()
}
