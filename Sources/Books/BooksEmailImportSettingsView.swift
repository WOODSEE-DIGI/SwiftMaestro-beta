import SwiftUI

// MARK: - Email import settings view

struct BooksEmailImportSettingsView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var settings: BooksEmailImportSettings
    @State private var lastResult: String?
    @State private var isScanning = false

    init() {
        _settings = State(initialValue: BooksEmailImportSettings.load())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Email Import")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            Text("Forward bills and receipts by email. Apple Mail rules or external services can drop .eml / .emlx files into the import folder below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                Toggle("Enable email import", isOn: $settings.isEnabled)

                HStack {
                    TextField("Import folder", text: Binding(
                        get: { settings.importFolderURL ?? BooksEmailImportService.defaultImportFolder.path },
                        set: { settings.importFolderURL = $0 }))
                    Button("Choose…") { chooseFolder() }
                }

                Toggle("Archive processed emails", isOn: $settings.archiveProcessed)

                Picker("Scan interval", selection: $settings.scanInterval) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                }
            }
            .formStyle(.grouped)

            Divider()

            Text("Apple Mail rule")
                .font(.headline)
            Text("Create a Mail rule that runs the following AppleScript on messages matching your receipts/bills. The script saves the email as an .eml file in the import folder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: .constant(mailRuleScript))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Copy AppleScript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mailRuleScript, forType: .string)
                }
                Spacer()
                Button {
                    Task { await scanNow() }
                } label: {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Scan Now")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
            }

            if let lastResult {
                Text(lastResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480)
        .background(theme.chatBackground)
        .onChange(of: settings) { _, _ in
            settings.save()
            BooksEmailImportService.shared.settings = settings
            BooksEmailImportService.shared.startMonitoring()
        }
        .onAppear {
            BooksEmailImportService.shared.settings = settings
            BooksEmailImportService.shared.startMonitoring()
        }
    }

    private var mailRuleScript: String {
        let folder = settings.resolvedImportFolder.path
        return """
        using terms from application "Mail"
            on perform mail action with messages (theMessages) for rule theRule
                tell application "Mail"
                    set exportFolder to "\(folder)"
                    do shell script "mkdir -p " & quoted form of exportFolder
                    repeat with eachMessage in theMessages
                        set msgSubject to subject of eachMessage
                        set msgID to message id of eachMessage
                        set safeName to do shell script "echo " & quoted form of (msgSubject & " " & msgID) & " | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-80"
                        set emlPath to exportFolder & "/" & safeName & ".eml"
                        set emlFile to open for access file emlPath with write permission
                        set eof of emlFile to 0
                        write (source of eachMessage) to emlFile
                        close access emlFile
                    end repeat
                end tell
            end perform mail action with messages
        end using terms from
        """
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let url = settings.importFolderURL.flatMap({ URL(fileURLWithPath: $0) }),
           FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            guard result == .OK, let url = panel.url else { return }
            settings.importFolderURL = url.path
        }
    }

    private func scanNow() async {
        isScanning = true
        defer { isScanning = false }
        let count = await BooksEmailImportService.shared.scanOnce()
        lastResult = count > 0 ? "Imported \(count) record(s)." : "No new emails to import."
    }
}
