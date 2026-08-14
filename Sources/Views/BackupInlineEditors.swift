import SwiftUI

// MARK: - Inline Destination Editor

struct InlineDestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService
    let destination: BackupDestination
    var onDone: () -> Void

    @State private var name: String
    @State private var isEnabled: Bool
    // S3
    @State private var s3Endpoint: String
    @State private var s3Bucket: String
    @State private var s3AccessKey: String
    @State private var s3SecretKey: String
    @State private var s3Region: String
    // SSH
    @State private var sshHost: String
    @State private var sshPort: String
    @State private var sshUser: String
    @State private var sshKeyPath: String
    @State private var sshRepoPath: String
    // Test
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testPassed: Bool?

    init(backupService: BackupService, destination: BackupDestination, onDone: @escaping () -> Void) {
        self.backupService = backupService
        self.destination = destination
        self.onDone = onDone
        _name = State(initialValue: destination.name)
        _isEnabled = State(initialValue: destination.isEnabled)
        switch destination.kind {
        case .s3(let config):
            _s3Endpoint = State(initialValue: config.endpoint)
            _s3Bucket = State(initialValue: config.bucket)
            _s3AccessKey = State(initialValue: config.accessKeyID)
            _s3SecretKey = State(initialValue: config.secretAccessKey)
            _s3Region = State(initialValue: config.region)
            _sshHost = State(initialValue: ""); _sshPort = State(initialValue: "22")
            _sshUser = State(initialValue: "root"); _sshKeyPath = State(initialValue: "")
            _sshRepoPath = State(initialValue: "")
        case .sftp(let config):
            _s3Endpoint = State(initialValue: ""); _s3Bucket = State(initialValue: "")
            _s3AccessKey = State(initialValue: ""); _s3SecretKey = State(initialValue: ""); _s3Region = State(initialValue: "")
            _sshHost = State(initialValue: config.host)
            _sshPort = State(initialValue: "\(config.port)")
            _sshUser = State(initialValue: config.username)
            _sshKeyPath = State(initialValue: config.keyPath)
            _sshRepoPath = State(initialValue: config.repositoryPath)
        case .local:
            _s3Endpoint = State(initialValue: ""); _s3Bucket = State(initialValue: "")
            _s3AccessKey = State(initialValue: ""); _s3SecretKey = State(initialValue: ""); _s3Region = State(initialValue: "")
            _sshHost = State(initialValue: ""); _sshPort = State(initialValue: "22")
            _sshUser = State(initialValue: "root"); _sshKeyPath = State(initialValue: "")
            _sshRepoPath = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: $isEnabled)
            if case .s3 = destination.kind {
                TextField("Endpoint", text: $s3Endpoint).textFieldStyle(.roundedBorder)
                TextField("Bucket", text: $s3Bucket).textFieldStyle(.roundedBorder)
                TextField("Access Key ID", text: $s3AccessKey).textFieldStyle(.roundedBorder)
                SecureField("Secret Access Key", text: $s3SecretKey).textFieldStyle(.roundedBorder)
                TextField("Region", text: $s3Region).textFieldStyle(.roundedBorder)
            }
            if case .sftp = destination.kind {
                TextField("Host", text: $sshHost).textFieldStyle(.roundedBorder)
                TextField("Port", text: $sshPort).textFieldStyle(.roundedBorder)
                TextField("Username", text: $sshUser).textFieldStyle(.roundedBorder)
                TextField("SSH Key Path", text: $sshKeyPath).textFieldStyle(.roundedBorder)
                TextField("Repository Path", text: $sshRepoPath).textFieldStyle(.roundedBorder)
            }
            if let result = testResult {
                HStack {
                    Image(systemName: testPassed == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testPassed == true ? .green : .red)
                    Text(result).font(.caption).foregroundStyle(testPassed == true ? .green : .red)
                }
            }
            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting { ProgressView().controlSize(.small) } else { Label("Test Connection", systemImage: "network") }
                }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(isTesting)
                Spacer()
                Button("Cancel") { onDone() }.buttonStyle(.bordered).controlSize(.small)
                Button("Save") {
                    var dest = destination; dest.name = name; dest.isEnabled = isEnabled
                    if case .s3(var config) = dest.kind {
                        config.endpoint = s3Endpoint; config.bucket = s3Bucket
                        config.accessKeyID = s3AccessKey; config.secretAccessKey = s3SecretKey; config.region = s3Region
                        dest.kind = .s3(config)
                    }
                    if case .sftp = destination.kind {
                        let port = Int(sshPort) ?? 22
                        let config = BackupDestination.SFTPConfig(host: sshHost, port: port, username: sshUser, keyPath: sshKeyPath, repositoryPath: sshRepoPath)
                        dest.kind = .sftp(config)
                    }
                    backupService.updateDestination(dest); onDone()
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(name.isEmpty)
            }
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func testConnection() async {
        isTesting = true; testResult = nil; testPassed = nil

        // Read the real password from file
        let pwFile = NSHomeDirectory() + "/.restic-password"
        let realPassword = (try? String(contentsOfFile: pwFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !realPassword.isEmpty else {
            testResult = "No password found — create ~/.restic-password first"
            testPassed = false; isTesting = false; return
        }

        let testDest: BackupDestination
        switch destination.kind {
        case .s3:
            let config = BackupDestination.S3Config(endpoint: s3Endpoint, bucket: s3Bucket, accessKeyID: s3AccessKey, secretAccessKey: s3SecretKey, region: s3Region, usePathStyle: true)
            testDest = BackupDestination(name: "test", kind: .s3(config))
        case .sftp:
            let port = Int(sshPort) ?? 22
            let config = BackupDestination.SFTPConfig(host: sshHost, port: port, username: sshUser, keyPath: sshKeyPath, repositoryPath: sshRepoPath)
            testDest = BackupDestination(name: "test", kind: .sftp(config))
        case .local:
            testResult = "Local backup — no connection test needed"; testPassed = true; isTesting = false; return
        }

        // Test: list existing snapshots in the repository
        do {
            let output = try await backupService.listSnapshots(destination: testDest, password: realPassword)
            let count = output.components(separatedBy: "\n").filter { $0.contains("snapshot") }.count
            testResult = "Connected — \(count) snapshot(s) found in repository"
            testPassed = true
        } catch {
            let msg = error.localizedDescription
            if msg.contains("repository") && msg.contains("not found") {
                // Repository doesn't exist yet — try to create it
                do {
                    _ = try await backupService.initRepository(destination: testDest, password: realPassword)
                    testResult = "Connected — new repository created"
                    testPassed = true
                } catch {
                    testResult = "Failed: \(error.localizedDescription.prefix(100))"
                    testPassed = false
                }
            } else {
                testResult = "Failed: \(msg.prefix(100))"
                testPassed = false
            }
        }
        isTesting = false
    }
}

// MARK: - Inline Job Editor

struct InlineJobEditor: View {
    @Bindable var backupService: BackupService
    let job: BackupJob
    var onDone: () -> Void

    @State private var name: String
    @State private var sourcePaths: [String]
    @State private var excludePatterns: [String]
    @State private var selectedDestinationID: UUID?
    @State private var scheduleType: Int
    @State private var showingExcludePicker = false

    init(backupService: BackupService, job: BackupJob, onDone: @escaping () -> Void) {
        self.backupService = backupService
        self.job = job
        self.onDone = onDone
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Job Name", text: $name).textFieldStyle(.roundedBorder)

            // Source paths
            Text("Source Directories").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(sourcePaths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tertiary)
                    Text(path).font(.caption).lineLimit(1)
                    Spacer()
                    Button { sourcePaths.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                }
            }
            Button {
                openDirectoryPicker { urls in
                    sourcePaths.append(contentsOf: urls.map(\.path))
                    sourcePaths = Array(Set(sourcePaths)).sorted()
                }
            } label: { Label("Add Directory", systemImage: "plus").font(.caption) }.buttonStyle(.plain)

            // Destination
            Picker("Backup To", selection: $selectedDestinationID) {
                Text("Select...").tag(nil as UUID?)
                ForEach(backupService.destinations) { dest in Text(dest.name).tag(dest.id as UUID?) }
            }

            // Schedule
            Picker("Schedule", selection: $scheduleType) {
                Text("Manual").tag(0); Text("Daily").tag(1); Text("Weekly").tag(2)
            }.pickerStyle(.segmented)

            // Excludes
            Text("Excludes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(excludePatterns, id: \.self) { pattern in
                HStack {
                    Image(systemName: "folder.badge.minus").foregroundStyle(.tertiary)
                    Text(pattern).font(.caption)
                    Spacer()
                    Button { excludePatterns.removeAll { $0 == pattern } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                }
            }
            Button {
                openDirectoryPicker { urls in
                    for url in urls { let n = url.lastPathComponent; if !excludePatterns.contains(n) { excludePatterns.append(n) } }
                }
            } label: { Label("Exclude Directory", systemImage: "plus").font(.caption) }.buttonStyle(.plain)

            HStack {
                Button("Delete", role: .destructive) { backupService.deleteJob(job); onDone() }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("Cancel") { onDone() }.buttonStyle(.bordered).controlSize(.small)
                Button("Save") {
                    var updated = job; updated.name = name; updated.sourcePaths = sourcePaths
                    updated.excludePatterns = excludePatterns; updated.destinationID = selectedDestinationID ?? job.destinationID
                    backupService.updateJob(updated); onDone()
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(name.isEmpty || sourcePaths.isEmpty)
            }
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fileImporter(isPresented: $showingExcludePicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { let n = url.lastPathComponent; if !excludePatterns.contains(n) { excludePatterns.append(n) } }
        }
    }

    private func openDirectoryPicker(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel(); panel.title = "Select Directories"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { completion(panel.urls) } }
    }
}

// MARK: - Inline New Destination

struct InlineNewDestination: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService
    @State private var name = "Onidel Sydney"
    @State private var s3Endpoint = "https://s3.ap-southeast-2.onidel.cloud"
    @State private var s3Bucket = "woodsee-backups"
    @State private var s3AccessKey = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "secret.global.onidel-access-key")) ?? ""
    @State private var s3SecretKey = (try? KeychainService.read(service: "com.woodseedigi.swiftmaestro", account: "secret.global.onidel-secret-key")) ?? ""
    @State private var s3Region = "ap-southeast-2"
    @State private var selectedType = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "externaldrive").font(.title3).foregroundStyle(Color.accentColor); Text("New Destination").font(.headline); Spacer(); Button("Cancel") { dismiss() } }.padding()
            Divider()
            Form {
                Section("General") { TextField("Name", text: $name) }
                Section("Storage Type") {
                    Picker("Type", selection: $selectedType) { Text("S3 Compatible").tag(0); Text("SSH / SFTP").tag(1); Text("Local Path").tag(2) }.pickerStyle(.segmented)
                }
                if selectedType == 0 {
                    Section("S3 Configuration") {
                        TextField("Endpoint", text: $s3Endpoint); TextField("Bucket", text: $s3Bucket)
                        TextField("Access Key ID", text: $s3AccessKey); SecureField("Secret Access Key", text: $s3SecretKey)
                        TextField("Region", text: $s3Region)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Add Destination") {
                    let config = BackupDestination.S3Config(endpoint: s3Endpoint, bucket: s3Bucket, accessKeyID: s3AccessKey, secretAccessKey: s3SecretKey, region: s3Region, usePathStyle: true)
                    backupService.addDestination(BackupDestination(name: name, kind: .s3(config)))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty)
            }.padding()
        }.frame(width: 500, height: 500)
    }
}

// MARK: - Inline New Job

struct InlineNewJob: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var backupService: BackupService
    @State private var name = ""
    @State private var sourcePaths: [String] = []
    @State private var excludePatterns = BackupJob.defaultExcludes
    @State private var selectedDestinationID: UUID?
    @State private var scheduleType = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "list.bullet.rectangle").font(.title3).foregroundStyle(Color.accentColor); Text("New Backup Job").font(.headline); Spacer(); Button("Cancel") { dismiss() } }.padding()
            Divider()
            Form {
                Section("General") { TextField("Job Name", text: $name, prompt: Text("e.g. Critical Files")) }
                Section("Source Directories") {
                    ForEach(sourcePaths, id: \.self) { path in
                        HStack { Image(systemName: "folder.fill").foregroundStyle(.tertiary); Text(path).font(.caption).lineLimit(1); Spacer()
                            Button { sourcePaths.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain) }
                    }
                    Button { openDirectoryPicker { urls in sourcePaths.append(contentsOf: urls.map(\.path)); sourcePaths = Array(Set(sourcePaths)).sorted() } }
                        label: { Label("Add Directory", systemImage: "plus").font(.caption) }.buttonStyle(.plain)
                }
                Section("Destination") {
                    Picker("Backup To", selection: $selectedDestinationID) {
                        Text("Select...").tag(nil as UUID?)
                        ForEach(backupService.destinations) { dest in Text(dest.name).tag(dest.id as UUID?) }
                    }
                }
                Section("Schedule") {
                    Picker("Schedule", selection: $scheduleType) { Text("Manual").tag(0); Text("Daily").tag(1); Text("Weekly").tag(2) }.pickerStyle(.segmented)
                }
                Section("Excludes") {
                    ForEach(excludePatterns, id: \.self) { pattern in
                        HStack { Image(systemName: "folder.badge.minus").foregroundStyle(.tertiary); Text(pattern).font(.caption); Spacer()
                            Button { excludePatterns.removeAll { $0 == pattern } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain) }
                    }
                    Button { openDirectoryPicker { urls in for url in urls { let n = url.lastPathComponent; if !excludePatterns.contains(n) { excludePatterns.append(n) } } } }
                        label: { Label("Exclude Directory", systemImage: "plus").font(.caption) }.buttonStyle(.plain)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Create Job") {
                    let schedule: BackupJob.Schedule = scheduleType == 1 ? .daily(hour: 2, minute: 0) : scheduleType == 2 ? .weekly(weekday: 1, hour: 2, minute: 0) : .manual
                    backupService.addJob(BackupJob(name: name, sourcePaths: sourcePaths, excludePatterns: excludePatterns, destinationID: selectedDestinationID ?? UUID(), schedule: schedule))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty || sourcePaths.isEmpty || selectedDestinationID == nil)
            }.padding()
        }.frame(width: 500, height: 600)
    }

    private func openDirectoryPicker(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel(); panel.title = "Select Directories"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { completion(panel.urls) } }
    }
}
