import SwiftUI

struct BackupStatusPanel: View {
    @State private var backupService = BackupService()
    @State private var isVerifying = false
    @State private var verifyResult: String?

    // Inline editing state
    @State private var editingDestination: BackupDestination?
    @State private var editingJob: BackupJob?
    @State private var showingNewDestination = false
    @State private var showingNewJob = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Live status (when backup running)
            if backupService.currentState.phase != .idle {
                statusSection
                Divider()
            }

            // Verify result
            if let result = verifyResult {
                verifyBanner(result)
                Divider()
            }

            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Destinations
                    destinationsSection

                    // Jobs
                    jobsSection

                    // Logs
                    logsSection
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
        .sheet(item: $editingDestination) { dest in
            EditDestinationSheet(backupService: backupService, destination: dest)
        }
        .sheet(item: $editingJob) { job in
            EditJobSheet(backupService: backupService, job: job)
        }
        .sheet(isPresented: $showingNewDestination) {
            NewDestinationSheet(backupService: backupService)
        }
        .sheet(isPresented: $showingNewJob) {
            NewJobSheet(backupService: backupService)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Backup")
                .font(.headline)
            Spacer()
            Button {
                Task { await verifyAll() }
            } label: {
                if isVerifying {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isVerifying)
            .help("Verify repository integrity")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(backupService.currentState.phase == .finished ? 0 : 1)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if backupService.currentState.phase != .finished && backupService.currentState.phase != .idle {
                    Button("Cancel") {
                        backupService.cancelBackup()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if backupService.currentState.totalBytes > 0 {
                ProgressView(value: backupService.currentState.progressFraction)
                    .tint(Color.accentColor)

                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: backupService.currentState.bytesUploaded, countStyle: .file))
                        .font(.caption.monospacedDigit())
                    Text("/")
                    Text(ByteCountFormatter.string(fromByteCount: backupService.currentState.totalBytes, countStyle: .file))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    if backupService.currentState.speed > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(backupService.currentState.speed), countStyle:.file))/s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }

            if !backupService.currentState.currentFile.isEmpty {
                Text(backupService.currentState.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch backupService.currentState.phase {
        case .idle: return "Idle"
        case .scanning: return "Scanning files..."
        case .uploading: return "Uploading..."
        case .pruning: return "Pruning old snapshots..."
        case .finished: return "Backup complete"
        }
    }

    // MARK: - Verify Banner

    private func verifyBanner(_ result: String) -> some View {
        HStack {
            Text(result)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                verifyResult = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(result.contains("✅") ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
    }

    // MARK: - Destinations Section

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "externaldrive")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                Text("Destinations")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingNewDestination = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            if backupService.destinations.isEmpty {
                emptyCard("No destinations", "Add an S3 bucket, SSH server, or local path.")
            } else {
                ForEach(backupService.destinations) { dest in
                    destinationRow(dest)
                }
            }
        }
    }

    private func destinationRow(_ dest: BackupDestination) -> some View {
        HStack {
            Image(systemName: dest.kind.icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(dest.name)
                    .font(.subheadline)
                Text(dest.kind.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if dest.isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Button {
                editingDestination = dest
            } label: {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Jobs Section

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                Text("Backup Jobs")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingNewJob = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            if backupService.jobs.isEmpty {
                emptyCard("No backup jobs", "Create a job to select directories and schedule backups.")
            } else {
                ForEach(backupService.jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: BackupJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.subheadline)
                Text("\(job.sourcePaths.count) paths · \(job.schedule.displayDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lastRun = job.lastRunDate {
                    Text("Last: \(lastRun.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                editingJob = job
            } label: {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button {
                Task { await runBackup(job) }
            } label: {
                if backupService.currentState.jobID == job.id && backupService.currentState.phase != .idle && backupService.currentState.phase != .finished {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(backupService.currentState.phase != .idle && backupService.currentState.phase != .finished)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Logs Section

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                Text("History")
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
            Circle()
                .fill(logStatusColor(log.status))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                if let size = log.totalSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let err = log.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let verified = log.checksumVerified {
                Image(systemName: verified ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(verified ? .green : .red)
                    .font(.caption2)
            }
            if let duration = log.duration {
                Text("\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func logStatusColor(_ status: BackupLogEntry.Status) -> Color {
        switch status {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    // MARK: - Empty Card

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func runBackup(_ job: BackupJob) async {
        // Trigger the launchd backup script (runs independently of the app)
        backupService.currentState = BackupState(jobID: job.id, phase: .scanning)
        try? await backupService.triggerLaunchdBackup()
        // Refresh logs after a short delay to pick up the new log file
        try? await Task.sleep(for: .seconds(2))
        backupService.load()
        backupService.currentState.phase = .idle
    }

    private func verifyAll() async {
        isVerifying = true
        verifyResult = nil
        for dest in backupService.destinations where dest.isEnabled {
            let password = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "backup-repo-\(dest.id.uuidString)")) ?? ""
            guard !password.isEmpty else { continue }
            let result = try? await backupService.verifyRepository(destination: dest, password: password)
            if let result = result {
                verifyResult = result.passed ? "✅ \(dest.name): Integrity verified" : "❌ \(dest.name): \(result.output.prefix(100))"
            }
        }
        isVerifying = false
    }
}

// MARK: - Edit Destination Sheet

struct EditDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService
    let destination: BackupDestination

    @State private var name: String
    @State private var isEnabled: Bool
    @State private var s3Endpoint: String
    @State private var s3Bucket: String
    @State private var s3AccessKey: String
    @State private var s3SecretKey: String
    @State private var s3Region: String
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testPassed: Bool?

    init(backupService: BackupService, destination: BackupDestination) {
        self.backupService = backupService
        self.destination = destination
        _name = State(initialValue: destination.name)
        _isEnabled = State(initialValue: destination.isEnabled)
        switch destination.kind {
        case .s3(let config):
            _s3Endpoint = State(initialValue: config.endpoint)
            _s3Bucket = State(initialValue: config.bucket)
            _s3AccessKey = State(initialValue: config.accessKeyID)
            _s3SecretKey = State(initialValue: config.secretAccessKey)
            _s3Region = State(initialValue: config.region)
        case .sftp, .local:
            _s3Endpoint = State(initialValue: "")
            _s3Bucket = State(initialValue: "")
            _s3AccessKey = State(initialValue: "")
            _s3SecretKey = State(initialValue: "")
            _s3Region = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Edit Destination")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $isEnabled)
                }
                if case .s3 = destination.kind {
                    Section("S3 Configuration") {
                        TextField("Endpoint", text: $s3Endpoint)
                        TextField("Bucket", text: $s3Bucket)
                        TextField("Access Key ID", text: $s3AccessKey)
                        SecureField("Secret Access Key", text: $s3SecretKey)
                        TextField("Region", text: $s3Region)
                    }
                }

                // Test result
                if let result = testResult {
                    Section("Connection Test") {
                        HStack {
                            Image(systemName: testPassed == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testPassed == true ? .green : .red)
                                .font(.title3)
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(testPassed == true ? .green : .red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                // Test Connection button
                if case .s3 = destination.kind {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting || s3AccessKey.isEmpty || s3SecretKey.isEmpty)
                }
                Spacer()
                Button("Save") {
                    var dest = destination
                    dest.name = name
                    dest.isEnabled = isEnabled
                    if case .s3(var config) = dest.kind {
                        config.endpoint = s3Endpoint
                        config.bucket = s3Bucket
                        config.accessKeyID = s3AccessKey
                        config.secretAccessKey = s3SecretKey
                        config.region = s3Region
                        dest.kind = .s3(config)
                    }
                    backupService.updateDestination(dest)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testPassed = nil

        // Build a test destination with the current form values
        let config = BackupDestination.S3Config(
            endpoint: s3Endpoint,
            bucket: s3Bucket,
            accessKeyID: s3AccessKey,
            secretAccessKey: s3SecretKey,
            region: s3Region,
            usePathStyle: true
        )
        let testDest = BackupDestination(name: "test", kind: .s3(config))

        // Generate a random test password for the init
        let testPass = "test-\(UUID().uuidString)"
        let testFile = NSTemporaryDirectory() + "/restic-test-pass.txt"
        try? testPass.write(toFile: testFile, atomically: true, encoding: .utf8)

        do {
            let output = try await backupService.initRepository(destination: testDest, password: testPass)
            testResult = "Connected — bucket is accessible"
            testPassed = true
            // Clean up the test repository
            _ = try? await backupService.runRestic(args: [
                "-r", BackupService.repositoryURL(for: testDest),
                "forget", "--host", Host.current().localizedName ?? "test", "--keep-last", "0", "--prune"
            ], environment: BackupService.environment(for: testDest, password: testPass))
        } catch {
            let msg = error.localizedDescription
            if msg.contains("already exists") {
                testResult = "Connected — repository exists (OK)"
                testPassed = true
            } else if msg.contains("config") || msg.contains("auth") || msg.contains("403") {
                testResult = "Auth failed — check Access Key and Secret Key"
                testPassed = false
            } else {
                testResult = "Failed: \(msg.prefix(80))"
                testPassed = false
            }
        }

        try? FileManager.default.removeItem(atPath: testFile)
        isTesting = false
    }
}

// MARK: - Edit Job Sheet

struct EditJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService
    let job: BackupJob

    @State private var name: String
    @State private var sourcePaths: [String]
    @State private var excludePatterns: [String]
    @State private var selectedDestinationID: UUID?
    @State private var scheduleType: Int
    @State private var scheduleHour: Int
    @State private var scheduleWeekday: Int
    @State private var showingPathPicker = false
    @State private var showingExcludePicker = false

    init(backupService: BackupService, job: BackupJob) {
        self.backupService = backupService
        self.job = job
        _name = State(initialValue: job.name)
        _sourcePaths = State(initialValue: job.sourcePaths)
        _excludePatterns = State(initialValue: job.excludePatterns)
        _selectedDestinationID = State(initialValue: job.destinationID)
        switch job.schedule {
        case .manual: _scheduleType = State(initialValue: 0)
        case .daily: _scheduleType = State(initialValue: 1)
        case .weekly: _scheduleType = State(initialValue: 2)
        default: _scheduleType = State(initialValue: 0)
        }
        _scheduleHour = State(initialValue: 2)
        _scheduleWeekday = State(initialValue: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Job")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    TextField("Job Name", text: $name)
                }

                Section("Source Directories") {
                    ForEach(sourcePaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                sourcePaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        openDirectoryPicker { urls in
                            sourcePaths.append(contentsOf: urls.map(\.path))
                            sourcePaths = Array(Set(sourcePaths)).sorted()
                        }
                    } label: {
                        Label("Add Directory", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                }

                Section("Destination") {
                    Picker("Backup To", selection: $selectedDestinationID) {
                        Text("Select...").tag(nil as UUID?)
                        ForEach(backupService.destinations) { dest in
                            Text(dest.name).tag(dest.id as UUID?)
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Schedule", selection: $scheduleType) {
                        Text("Manual").tag(0)
                        Text("Daily").tag(1)
                        Text("Weekly").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Excludes") {
                    ForEach(excludePatterns, id: \.self) { pattern in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(.secondary)
                            Text(pattern)
                                .font(.caption)
                            Spacer()
                            Button {
                                excludePatterns.removeAll { $0 == pattern }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        openDirectoryPicker { urls in
                            for url in urls {
                                let name = url.lastPathComponent
                                if !excludePatterns.contains(name) {
                                    excludePatterns.append(name)
                                }
                            }
                        }
                    } label: {
                        Label("Exclude Directory", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Delete Job", role: .destructive) {
                    backupService.deleteJob(job)
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    var updated = job
                    updated.name = name
                    updated.sourcePaths = sourcePaths
                    updated.excludePatterns = excludePatterns
                    updated.destinationID = selectedDestinationID ?? job.destinationID
                    backupService.updateJob(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || sourcePaths.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
    }

    private func openDirectoryPicker(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Directories"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK {
                completion(panel.urls)
            }
        }
    }
}
