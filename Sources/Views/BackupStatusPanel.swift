import SwiftUI

// MARK: - Main Panel

struct BackupStatusPanel: View {
    @State private var backupService = BackupService()
    @State private var editingDestinationID: UUID?
    @State private var editingJobID: UUID?
    @State private var showingNewDestination = false
    @State private var showingNewJob = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if backupService.currentState.phase != .idle {
                statusSection
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationsSection
                    Divider()
                    jobsSection
                    Divider()
                    logsSection
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingNewDestination) {
            InlineNewDestination(backupService: backupService)
        }
        .sheet(isPresented: $showingNewJob) {
            InlineNewJob(backupService: backupService)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Backup")
                .font(.title2.bold())
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Backup in Progress")
                    .font(.headline)
                Spacer()
                Button("Cancel") { backupService.cancelBackup() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.bottom, 8)

            Text("Scanning identifies changed files, then uploads them to your VPS. Both happen together.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            // Step 1: Scanning
            let scanDone = backupService.currentState.scanComplete
            let scanActive = backupService.currentState.phase == .running && !scanDone
            let filesScanned = backupService.currentState.filesScanned
            stepRow(
                number: 1,
                label: "Scanning files",
                detail: scanDone
                    ? "\(filesScanned.formatted()) files identified"
                    : scanActive
                        ? filesScanned > 0 ? "\(filesScanned.formatted()) files so far..." : "Counting files..."
                        : "Waiting to start",
                isDone: scanDone,
                isActive: scanActive
            )

            // Step 2: Uploading
            let uploadActive = backupService.currentState.phase == .running && scanDone
            let uploadDone = backupService.currentState.uploadComplete
            let totalBytes = backupService.currentState.totalBytes
            let uploadedBytes = backupService.currentState.bytesUploaded
            stepRow(
                number: 2,
                label: "Uploading to VPS",
                detail: uploadDone
                    ? "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) uploaded"
                    : uploadActive && totalBytes > 0
                        ? "\(ByteCountFormatter.string(fromByteCount: uploadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                        : "Waiting for scan to finish",
                isDone: uploadDone,
                isActive: uploadActive
            )

            // Progress bar only during active upload
            if uploadActive && totalBytes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: backupService.currentState.progressFraction)
                        .tint(Color.accentColor)
                    HStack {
                        let speed = backupService.currentState.speed
                        Text(speed > 0 ? "Speed: \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle:.file))/s" : "Calculating speed...")
                        Spacer()
                        let pct = Int(backupService.currentState.progressFraction * 100)
                        Text("\(pct)%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            // Step 3: Pruning
            let pruneActive = backupService.currentState.phase == .pruning
            let pruneDone = backupService.currentState.phase == .finished
            stepRow(
                number: 3,
                label: "Pruning old snapshots",
                detail: nil,
                isDone: pruneDone,
                isActive: pruneActive
            )

            // Step 4: Complete
            stepRow(
                number: 4,
                label: "Backup complete",
                detail: nil,
                isDone: backupService.currentState.phase == .finished,
                isActive: false
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.05))
    }

    private func stepRow(number: Int, label: String, detail: String?, isDone: Bool, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else if isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .stroke(.secondary, lineWidth: 2)
                    .frame(width: 20, height: 20)
                    .overlay(Text("\(number)").font(.caption2).foregroundStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(isActive ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(!isDone && !isActive ? .secondary : .primary)
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Destinations

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "externaldrive").font(.title3).foregroundStyle(Color.accentColor)
                Text("Destinations").font(.title3.bold())
                Spacer()
                Button { showingNewDestination = true } label: {
                    Label("Add Destination", systemImage: "plus").font(.subheadline)
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if backupService.destinations.isEmpty {
                emptyCard("No destinations", "Add an S3 bucket, SSH server, or local path.")
            } else {
                ForEach(backupService.destinations) { dest in
                    if editingDestinationID == dest.id {
                        InlineDestinationEditor(backupService: backupService, destination: dest) { editingDestinationID = nil }
                    } else {
                        destinationCard(dest)
                    }
                }
            }
        }
    }

    private func destinationCard(_ dest: BackupDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: dest.kind.icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dest.name).font(.headline)
                    Text(dest.kind.description).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if dest.isEnabled {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if case .s3(let config) = dest.kind {
                    labeledRow("Endpoint", config.endpoint)
                    labeledRow("Bucket", config.bucket)
                    labeledRow("Access Key", mask(config.accessKeyID))
                }
                if case .sftp(let config) = dest.kind {
                    labeledRow("Host", "\(config.username)@\(config.host):\(config.port)")
                    labeledRow("Repository", config.repositoryPath)
                }
            }.padding(.leading, 38).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Edit") { editingDestinationID = dest.id }.buttonStyle(.bordered).controlSize(.small)
                Button("Delete", role: .destructive) { backupService.deleteDestination(dest) }.buttonStyle(.bordered).controlSize(.small)
            }.padding(.leading, 38)
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Jobs

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "list.bullet.rectangle").font(.title3).foregroundStyle(Color.accentColor)
                Text("Backup Jobs").font(.title3.bold())
                Spacer()
                Button { showingNewJob = true } label: {
                    Label("Add Job", systemImage: "plus").font(.subheadline)
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if backupService.jobs.isEmpty {
                emptyCard("No backup jobs", "Create a job to select directories and schedule backups.")
            } else {
                ForEach(backupService.jobs) { job in
                    if editingJobID == job.id {
                        InlineJobEditor(backupService: backupService, job: job) { editingJobID = nil }
                    } else {
                        jobCard(job)
                    }
                }
            }
        }
    }

    private func jobCard(_ job: BackupJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.headline)
                    Text("\(job.sourcePaths.count) paths · \(job.schedule.displayDescription)").font(.subheadline).foregroundStyle(.secondary)
                    if let lastRun = job.lastRunDate {
                        Text("Last: \(lastRun.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    Task { await runBackup(job) }
                } label: {
                    if backupService.currentState.jobID == job.id && backupService.currentState.phase != .idle && backupService.currentState.phase != .finished {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill").font(.subheadline)
                    }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(backupService.currentState.phase != .idle && backupService.currentState.phase != .finished)
            }
            // Show configured paths inline
            VStack(alignment: .leading, spacing: 3) {
                ForEach(job.sourcePaths.prefix(5), id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").foregroundStyle(.tertiary)
                        Text(path).font(.caption).lineLimit(1)
                    }
                }
                if job.sourcePaths.count > 5 {
                    Text("+ \(job.sourcePaths.count - 5) more").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(.leading, 4).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Edit") { editingJobID = job.id }.buttonStyle(.bordered).controlSize(.small)
                Button("Delete", role: .destructive) { backupService.deleteJob(job) }.buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(Color.accentColor)
                Text("History").font(.title3.bold())
            }
            if backupService.logs.isEmpty {
                emptyCard("No history", "Run a backup to see logs here.")
            } else {
                ForEach(backupService.logs.prefix(10)) { log in
                    logRow(log)
                }
            }
        }
    }

    private func logRow(_ log: BackupLogEntry) -> some View {
        HStack(spacing: 8) {
            Circle().fill(logStatusColor(log.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(log.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                if let size = log.totalSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                if let err = log.errorMessage { Text(err).font(.caption).foregroundStyle(.red).lineLimit(1) }
            }
            Spacer()
            if let verified = log.checksumVerified {
                Image(systemName: verified ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(verified ? .green : .red).font(.caption)
            }
            if let duration = log.duration {
                Text("\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }

    private func logStatusColor(_ status: BackupLogEntry.Status) -> Color {
        switch status { case .running: .blue; case .completed: .green; case .failed: .red; case .cancelled: .orange }
    }

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) { Text(title).font(.subheadline.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack { Text("\(label):").foregroundStyle(.tertiary).frame(width: 75, alignment: .trailing); Text(value).lineLimit(1).textSelection(.enabled) }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 8 else { return key.isEmpty ? "—" : key }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }

    // MARK: - Actions

    private func runBackup(_ job: BackupJob) async {
        guard let dest = backupService.destinations.first(where: { $0.id == job.destinationID }) else { return }
        // Try Keychain first, then password file
        var password = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "backup-repo-\(dest.id.uuidString)")) ?? ""
        if password.isEmpty {
            let pwFile = NSHomeDirectory() + "/.restic-password"
            password = (try? String(contentsOfFile: pwFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }
        guard !password.isEmpty else { return }
        try? await backupService.runBackup(job: job, destination: dest, password: password)
    }

}
