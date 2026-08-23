import SwiftUI

// MARK: - Main Panel

struct BackupStatusPanel: View {
    /// Shared app-wide instance — a view-owned service would lose all live
    /// backup state every time SwiftUI destroys/recreates this panel when
    /// switching workspace panels mid-backup.
    private let backupService = BackupService.shared
    @State private var editingDestinationID: UUID?
    @State private var editingJobID: UUID?
    @State private var showingNewDestination = false
    @State private var showingNewJob = false
    @State private var verifyingDestinationID: UUID?
    @State private var verifyResults: [UUID: String] = [:]

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
        let state = backupService.currentState
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(statusTitle(for: state.phase))
                    .font(.headline)
                Spacer()
                if state.isActive {
                    Button("Cancel") { backupService.cancelBackup() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Clear") { backupService.dismissStatus() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.bottom, 8)

            if state.phase == .failed, let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.bottom, 10)
            } else {
                Text("Scanning identifies changed files, then uploads them to your VPS. Both happen together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }

            // Step 1: Scanning
            let scanDone = state.scanComplete
            let scanActive = state.phase == .running && !scanDone
            stepRow(
                number: 1,
                label: "Scanning files",
                detail: scanDone
                    ? "\(state.totalFiles.formatted()) files identified (\(Self.formatBytes(state.totalBytes)))"
                    : scanActive
                        ? state.totalFiles > 0
                            ? "\(state.totalFiles.formatted()) files found so far (\(Self.formatBytes(state.totalBytes)))..."
                            : "Counting files..."
                        : state.phase == .failed && state.totalFiles > 0
                            ? "\(state.totalFiles.formatted()) files found before failure"
                            : "Waiting to start",
                isDone: scanDone,
                isActive: scanActive
            )

            // Step 2: Uploading — restic scans and uploads concurrently, so show
            // live byte progress as soon as the first status line arrives.
            let uploadDone = state.uploadComplete
            stepRow(
                number: 2,
                label: "Uploading to VPS",
                detail: uploadDone
                    ? "\(Self.formatBytes(state.bytesUploaded)) uploaded"
                    : state.bytesUploaded > 0 || state.totalBytes > 0
                        ? "\(Self.formatBytes(state.bytesUploaded)) / \(Self.formatBytes(state.totalBytes))"
                        : scanDone ? "Starting upload..." : "Waiting for scan to finish",
                isDone: uploadDone,
                isActive: state.phase == .running && !uploadDone
            )

            // Progress bar while bytes are flowing
            if state.phase == .running && state.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: state.progressFraction)
                        .tint(Color.accentColor)
                    HStack {
                        Text(state.speed > 0 ? "\(Self.formatBytes(Int64(state.speed)))/s" : "Calculating speed...")
                        if let remaining = state.secondsRemaining, remaining > 1 {
                            Text("·")
                            Text("~\(Self.formatDuration(remaining)) left")
                        }
                        if state.errorCount > 0 {
                            Text("·")
                            Text("\(state.errorCount) unreadable")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(Int(state.progressFraction * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !state.currentFile.isEmpty {
                        Text(state.currentFile)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            // Step 3: Pruning — only shown as active/done now that the service
            // actually runs forget+prune after each successful backup.
            let pruneActive = state.phase == .pruning
            let pruneDone = state.pruneComplete
            stepRow(
                number: 3,
                label: "Pruning old snapshots",
                detail: pruneActive ? "Applying retention policy..." : pruneDone ? "Retention policy applied" : nil,
                isDone: pruneDone,
                isActive: pruneActive
            )

            // Step 4: Complete
            stepRow(
                number: 4,
                label: state.phase == .failed ? "Backup failed" : "Backup complete",
                detail: state.phase == .finished ? completionSummary(state) : nil,
                isDone: state.phase == .finished,
                isActive: false
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.05))
    }

    private func statusTitle(for phase: BackupState.Phase) -> String {
        switch phase {
        case .running, .pruning: return "Backup in Progress"
        case .finished: return "Backup Finished"
        case .failed: return "Backup Failed"
        case .idle: return "Backup"
        }
    }

    private func completionSummary(_ state: BackupState) -> String {
        var parts = ["\(state.filesScanned.formatted()) files", Self.formatBytes(state.bytesUploaded) + " uploaded"]
        if state.secondsElapsed > 1 {
            parts.append("in \(Self.formatDuration(state.secondsElapsed))")
        }
        if let snapshotID = state.snapshotID {
            parts.append("snapshot \(snapshotID.prefix(8))")
        }
        return parts.joined(separator: " · ")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
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
                Button {
                    Task { await verifyNow(dest) }
                } label: {
                    if verifyingDestinationID == dest.id {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Verifying…")
                        }
                    } else {
                        Text("Verify Now")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(verifyingDestinationID != nil)
                .help("Deep integrity check: re-reads every blob and re-verifies its SHA-256. Slow on large/network repositories.")
                Button("Delete", role: .destructive) { backupService.deleteDestination(dest) }.buttonStyle(.bordered).controlSize(.small)
            }.padding(.leading, 38)
            if let result = verifyResults[dest.id] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Deep verification passed") ? .green : .red)
                    .lineLimit(3)
                    .padding(.leading, 38)
            }
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
                    if backupService.currentState.jobID == job.id && backupService.currentState.isActive {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill").font(.subheadline)
                    }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(backupService.currentState.isActive)
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
        guard !password.isEmpty else {
            backupService.currentState = BackupState(jobID: job.id, phase: .failed, lastError: "No restic repository password found in Keychain or ~/.restic-password")
            return
        }
        do {
            try await backupService.runBackup(job: job, destination: dest, password: password)
        } catch {
            // Service already recorded the failure in currentState/logs; nothing more to do.
        }
    }

    /// Deep "Verify Now" action: restic `check --read-data` re-reads every
    /// blob in the repository and re-verifies its SHA-256 content ID.
    /// (Routine post-backup runs use the fast structural `check`; this is
    /// the exhaustive manual one.)
    private func verifyNow(_ dest: BackupDestination) async {
        verifyingDestinationID = dest.id
        defer { verifyingDestinationID = nil }

        var password = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "backup-repo-\(dest.id.uuidString)")) ?? ""
        if password.isEmpty {
            let pwFile = NSHomeDirectory() + "/.restic-password"
            password = (try? String(contentsOfFile: pwFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }
        guard !password.isEmpty else {
            verifyResults[dest.id] = "No repository password found in Keychain or ~/.restic-password"
            return
        }

        do {
            let result = try await backupService.verifyRepository(destination: dest, password: password)
            verifyResults[dest.id] = result.passed
                ? "Deep verification passed — every blob's SHA-256 re-verified."
                : "Verification FAILED: \(result.output.suffix(200))"
        } catch {
            verifyResults[dest.id] = "Verification error: \(error.localizedDescription)"
        }
    }

}
