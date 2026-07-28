import SwiftUI

struct StreamMixerView: View {
    @StateObject private var service = StreamMixerService.shared
    @State private var isEditing = false

    private var selectedRoute: MixerRoute? {
        service.selectedRouteID.flatMap { id in service.routes.first(where: { $0.id == id }) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $service.selectedRouteID) {
                ForEach(service.routes) { route in
                    routeRow(route)
                        .tag(route.id)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        service.removeRoute(id: service.routes[index].id)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Stream Mixer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let newRoute = MixerRoute.default()
                        service.addRoute(newRoute)
                        service.selectedRouteID = newRoute.id
                        isEditing = true
                    } label: {
                        Label("Add Route", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let route = selectedRoute {
                detailView(for: route)
            } else {
                ContentUnavailableView(
                    "Select a Route",
                    systemImage: "arrow.triangle.merge",
                    description: Text("Choose a route to bridge a source to a destination.")
                )
            }
        }
        .sheet(isPresented: $isEditing) {
            if let route = selectedRoute {
                MixerRouteEditorView(route: route, onSave: { updated in
                    service.updateRoute(updated)
                    service.selectedRouteID = updated.id
                })
            }
        }
    }

    private func routeRow(_ route: MixerRoute) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name)
                    .font(.headline)
                Text(service.snapshots[route.id]?.status.rawValue ?? "Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = service.snapshots[route.id], snapshot.status == .active {
                Button {
                    service.stop(routeID: route.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    service.start(routeID: route.id)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(!route.isEnabled)
            }
            Button {
                service.selectedRouteID = route.id
                isEditing = true
            } label: {
                Image(systemName: "pencil")
            }
        }
        .padding(.vertical, 4)
    }

    private func detailView(for route: MixerRoute) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name)
                        .font(.headline)
                    Text("→ \(route.destinationURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("From: \(route.sourceURL)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = service.snapshots[route.id] {
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
                    service.clearLogs(routeID: route.id)
                } label: {
                    Image(systemName: "clear")
                }
                .help("Clear logs")

                Button {
                    service.removeRoute(id: route.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Delete route")
            }
            .padding()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(service.snapshots[route.id]?.logs ?? [], id: \.self) { line in
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

    private func statusColor(_ status: MixerRouteStatus) -> Color {
        switch status {
        case .idle: return .secondary
        case .starting: return .orange
        case .active: return .green
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
    StreamMixerView()
}
