import SwiftUI

struct BackupSettingsTab: View {
    @Environment(\.dismiss) private var dismiss

    @State private var backupService = BackupService()
    @State private var selectedDestination: BackupDestination?
    @State private var selectedJob: BackupJob?
    @State private var showingNewDestination = false
    @State private var showingNewJob = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backup")
                        .font(.title2.bold())
                    Text("Back up your data to any S3-compatible storage, SFTP server, or local drive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Destinations Section
                sectionHeader("Destinations", icon: "externaldrive") {
                    showingNewDestination = true
                }

                if backupService.destinations.isEmpty {
                    emptyCard("No destinations configured", "Add an S3 bucket, SFTP server, or local path to start backing up.")
                } else {
                    ForEach(backupService.destinations) { dest in
                        destinationCard(dest)
                    }
                }

                Divider()

                // Jobs Section
                sectionHeader("Backup Jobs", icon: "list.bullet.rectangle") {
                    showingNewJob = true
                }

                if backupService.jobs.isEmpty {
                    emptyCard("No backup jobs", "Create a job to select which directories to back up and where.")
                } else {
                    ForEach(backupService.jobs) { job in
                        jobCard(job)
                    }
                }

                Divider()

                // Logs Section
                sectionHeader("Recent Activity", icon: "clock.arrow.circlepath", showAdd: false)

                if backupService.logs.isEmpty {
                    emptyCard("No backup history", "Run a backup to see logs here.")
                } else {
                    ForEach(backupService.logs.prefix(10)) { log in
                        logCard(log)
                    }
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingNewDestination) {
            NewDestinationSheet(backupService: backupService)
        }
        .sheet(isPresented: $showingNewJob) {
            NewJobSheet(backupService: backupService)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, showAdd: Bool = true, onAdd: (() -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
            Spacer()
            if showAdd, let onAdd = onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty Card

    private func emptyCard(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Destination Card

    private func destinationCard(_ dest: BackupDestination) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: dest.kind.icon)
                        .foregroundStyle(Color.accentColor)
                    Text(dest.name)
                        .font(.subheadline.weight(.medium))
                    if dest.isEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                Text(dest.kind.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedDestination = dest
            } label: {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Job Card

    private func jobCard(_ job: BackupJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.name)
                        .font(.subheadline.weight(.medium))
                    if job.isEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                Text("\(job.sourcePaths.count) paths · \(job.schedule.displayDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastRun = job.lastRunDate {
                    Text("Last run: \(lastRun.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                Task {
                    await runBackup(job)
                }
            } label: {
                if backupService.currentState.jobID == job.id && backupService.currentState.phase != .idle {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(backupService.currentState.phase != .idle)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Log Card

    private func logCard(_ log: BackupLogEntry) -> some View {
        HStack {
            Circle()
                .fill(log.status.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                if let size = log.totalSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let err = log.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let duration = log.duration {
                Text(log.duration ?? 0, format: .number) + Text("s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Run Backup

    private func runBackup(_ job: BackupJob) async {
        try? await backupService.triggerLaunchdBackup()
    }
}

// MARK: - BackupDestination.Kind Extensions

extension BackupDestination.Kind {
    var icon: String {
        switch self {
        case .s3: return "cloud"
        case .sftp: return "server.rack"
        case .local: return "externaldrive"
        }
    }

    var description: String {
        switch self {
        case .s3(let config):
            return "S3 · \(config.bucket) · \(config.endpoint)"
        case .sftp(let config):
            return "SSH · \(config.username)@\(config.host):\(config.repositoryPath)"
        case .local(let config):
            return "Local · \(config.path)"
        }
    }
}

// MARK: - BackupLogEntry.Status Extension

extension BackupLogEntry.Status {
    var color: Color {
        switch self {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

// MARK: - New Destination Sheet

struct NewDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService

    @State private var name = "Onidel Sydney"
    @State private var kind: BackupDestination.Kind = .s3(.init(endpoint: "", bucket: "", accessKeyID: "", secretAccessKey: "", region: "ap-southeast-2", usePathStyle: true))
    @State private var s3Endpoint = "https://s3.ap-southeast-2.onidel.cloud"
    @State private var s3Bucket = "woodsee-backups"
    @State private var s3AccessKey = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "secret.global.onidel-access-key")) ?? ""
    @State private var s3SecretKey = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "secret.global.onidel-secret-key")) ?? ""
    @State private var s3Region = "ap-southeast-2"
    @State private var s3PathStyle = true
    @State private var sftpHost = "216.176.239.20"
    @State private var sftpPort = 22
    @State private var sftpUser = "root"
    @State private var sftpKeyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"
    @State private var sftpRepoPath = "/mnt/backup/repo"
    @State private var localPath = ""
    @State private var selectedType = 0 // 0=S3, 1=SFTP, 2=Local
    @State private var showingKeyPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Destination")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("General") {
                    TextField("Name", text: $name, prompt: Text("e.g. Onidel Sydney"))
                }

                Section("Type") {
                    Picker("Storage Type", selection: $selectedType) {
                        Text("S3 Compatible").tag(0)
                        Text("SSH / SFTP").tag(1)
                        Text("Local Path").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedType) { _, newValue in
                        switch newValue {
                        case 0: kind = .s3(.init(endpoint: "", bucket: "", accessKeyID: "", secretAccessKey: "", region: "", usePathStyle: true))
                        case 1: kind = .sftp(.init(host: "", port: 22, username: "root", keyPath: "", repositoryPath: ""))
                        case 2: kind = .local(.init(path: ""))
                        default: break
                        }
                    }
                }

                if selectedType == 0 {
                    Section("S3 Configuration") {
                        TextField("Endpoint URL", text: $s3Endpoint, prompt: Text("https://s3.ap-southeast-2.onidel.cloud"))
                        TextField("Bucket Name", text: $s3Bucket, prompt: Text("my-backups"))
                        TextField("Access Key ID", text: $s3AccessKey)
                        SecureField("Secret Access Key", text: $s3SecretKey)
                        TextField("Region", text: $s3Region, prompt: Text("ap-southeast-2"))
                        Toggle("Path-style URLs", isOn: $s3PathStyle)
                    }
                }

                if selectedType == 1 {
                    Section("SSH / SFTP Configuration") {
                        TextField("Host", text: $sftpHost, prompt: Text("216.176.239.20"))
                        TextField("Port", value: $sftpPort, format: .number)
                        TextField("Username", text: $sftpUser, prompt: Text("root"))
                        HStack {
                            TextField("SSH Key Path", text: $sftpKeyPath)
                            Button {
                                showingKeyPicker = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Repository Path", text: $sftpRepoPath, prompt: Text("/mnt/backup/repo"))
                    }
                }

                if selectedType == 2 {
                    Section("Local Path") {
                        HStack {
                            TextField("Path", text: $localPath, prompt: Text("/Volumes/External/backup-repo"))
                            Button {
                                showingKeyPicker = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Add Destination") {
                    addDestination()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .fileImporter(isPresented: $showingKeyPicker, allowedContentTypes: [.folder, .data]) { result in
            if case .success(let url) = result {
                if selectedType == 1 {
                    sftpKeyPath = url.path
                } else {
                    localPath = url.path
                }
            }
        }
    }

    private func addDestination() {
        let dest: BackupDestination
        switch selectedType {
        case 0:
            let config = BackupDestination.S3Config(endpoint: s3Endpoint, bucket: s3Bucket, accessKeyID: s3AccessKey, secretAccessKey: s3SecretKey, region: s3Region, usePathStyle: s3PathStyle)
            dest = BackupDestination(name: name, kind: .s3(config))
        case 1:
            let config = BackupDestination.SFTPConfig(host: sftpHost, port: sftpPort, username: sftpUser, keyPath: sftpKeyPath, repositoryPath: sftpRepoPath)
            dest = BackupDestination(name: name, kind: .sftp(config))
        default:
            let config = BackupDestination.LocalConfig(path: localPath)
            dest = BackupDestination(name: name, kind: .local(config))
        }
        backupService.addDestination(dest)
    }
}

// MARK: - New Job Sheet

struct NewJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService

    @State private var name = ""
    @State private var sourcePaths: [String] = []
    @State private var excludePatterns = BackupJob.defaultExcludes
    @State private var selectedDestinationID: UUID?
    @State private var scheduleType = 0 // 0=manual, 1=daily, 2=weekly
    @State private var scheduleHour = 2
    @State private var scheduleMinute = 0
    @State private var scheduleWeekday = 1
    @State private var showingPathPicker = false
    @State private var showingExcludePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Backup Job")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    TextField("Job Name", text: $name, prompt: Text("e.g. Critical Files"))
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
                        Text("Select destination...").tag(nil as UUID?)
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

                    if scheduleType == 1 {
                        HStack {
                            Text("Time")
                            Spacer()
                            Picker("", selection: $scheduleHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text("\(h):00").tag(h)
                                }
                            }
                        }
                    }

                    if scheduleType == 2 {
                        Picker("Day", selection: $scheduleWeekday) {
                            Text("Sunday").tag(1)
                            Text("Monday").tag(2)
                            Text("Tuesday").tag(3)
                            Text("Wednesday").tag(4)
                            Text("Thursday").tag(5)
                            Text("Friday").tag(6)
                            Text("Saturday").tag(7)
                        }
                    }
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
                Spacer()
                Button("Create Job") {
                    addJob()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || sourcePaths.isEmpty || selectedDestinationID == nil)
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

    private func addJob() {
        let schedule: BackupJob.Schedule
        switch scheduleType {
        case 1: schedule = .daily(hour: scheduleHour, minute: scheduleMinute)
        case 2: schedule = .weekly(weekday: scheduleWeekday, hour: scheduleHour, minute: scheduleMinute)
        default: schedule = .manual
        }
        let job = BackupJob(name: name, sourcePaths: sourcePaths, excludePatterns: excludePatterns, destinationID: selectedDestinationID!, schedule: schedule)
        backupService.addJob(job)
    }
}
