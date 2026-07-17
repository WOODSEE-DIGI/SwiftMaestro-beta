import Foundation

// MARK: - Apple Notes service

/// Bridges SwiftMaestro to the native Apple Notes app via JXA (JavaScript for
/// Automation). Lists folders/notes, reads note bodies, and creates new notes.
/// All Apple Events run out-of-process via `/usr/bin/osascript` so the main
/// thread is never blocked waiting for Notes to launch or for the permission
/// dialog to be dismissed.
@Observable
@MainActor
final class AppleNotesService {

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: AuthorizationStatus = .notDetermined
    private(set) var folders: [AppleNotesFolder] = []
    var notes: [AppleNotesNote] = []
    private(set) var error: String?
    private(set) var isLoading = false

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private static let authorizedDefaultsKey = "appleNotes.authorized"

    init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            _ = try await runScript(Self.helloScript, arguments: [])
            status = .authorized
            error = nil
            UserDefaults.standard.set(true, forKey: Self.authorizedDefaultsKey)
        } catch {
            status = .denied
            self.error = "Apple Notes access denied or failed: \(error.localizedDescription)"
            UserDefaults.standard.set(false, forKey: Self.authorizedDefaultsKey)
        }
    }

    func loadIfPreviouslyAuthorized() async {
        guard UserDefaults.standard.bool(forKey: Self.authorizedDefaultsKey) else { return }
        await loadFolders()
    }

    // MARK: - Fetch

    func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let json = try await runScript(Self.listFoldersScript, arguments: [])
            let data = Data(json.utf8)
            folders = try decoder.decode([AppleNotesFolder].self, from: data)
            status = .authorized
            UserDefaults.standard.set(true, forKey: Self.authorizedDefaultsKey)
        } catch {
            self.error = error.localizedDescription
            if (error as NSError).code == -1743 || (error as NSError).code == -1740 {
                status = .denied
                UserDefaults.standard.set(false, forKey: Self.authorizedDefaultsKey)
            }
        }
    }

    func loadNotes(in folderID: String) async {
        isLoading = true
        defer { isLoading = false }
        error = nil

        do {
            let json = try await runScript(Self.listNotesScript, arguments: [folderID])
            let data = Data(json.utf8)
            notes = try decoder.decode([AppleNotesNote].self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadBody(for noteID: String) async throws -> String {
        let json = try await runScript(Self.getBodyScript, arguments: [noteID])
        let data = Data(json.utf8)
        let note = try decoder.decode(AppleNotesNote.self, from: data)
        return note.body ?? ""
    }

    // MARK: - Create

    func createNote(title: String, body: String, in folderID: String?) async throws {
        let folderArg = folderID ?? ""
        let json = try await runScript(Self.createNoteScript, arguments: [folderArg, title, body])
        let data = Data(json.utf8)
        _ = try decoder.decode(AppleNotesNote.self, from: data)
        if let folderID {
            await loadNotes(in: folderID)
        } else {
            await loadFolders()
        }
    }

    // MARK: - Script runner

    /// Runs a JXA script through `/usr/bin/osascript` off the main actor.
    /// Throws a localized error if the script fails or the user denies permission.
    private nonisolated func runScript(_ source: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source] + arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = stderr.isEmpty ? output : stderr
                throw AppleNotesError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    // MARK: - Scripts

    private static let helloScript = """
    function run(argv) {
        var Notes = Application('Notes');
        Notes.name();
        return "ok";
    }
    """

    private static let listFoldersScript = """
    function run(argv) {
        var Notes = Application('Notes');
        var folders = [];
        Notes.accounts().forEach(function(account) {
            account.folders().forEach(function(folder) {
                folders.push({ id: folder.id(), name: folder.name() });
            });
        });
        return JSON.stringify(folders);
    }
    """

    private static let listNotesScript = """
    function run(argv) {
        var Notes = Application('Notes');
        var folderID = argv[0];
        var accounts = Notes.accounts();
        var matches = [];
        for (var i = 0; i < accounts.length; i++) {
            var folders = accounts[i].folders();
            for (var j = 0; j < folders.length; j++) {
                if (folders[j].id() === folderID) {
                    folders[j].notes().forEach(function(note) {
                        var mod = note.modificationDate();
                        matches.push({
                            id: note.id(),
                            name: note.name(),
                            folderID: folderID,
                            modified: mod ? mod.toISOString() : null,
                            body: null
                        });
                    });
                    return JSON.stringify(matches);
                }
            }
        }
        return JSON.stringify(matches);
    }
    """

    private static let getBodyScript = """
    function run(argv) {
        var Notes = Application('Notes');
        var noteID = argv[0];
        var accounts = Notes.accounts();
        for (var i = 0; i < accounts.length; i++) {
            var folders = accounts[i].folders();
            for (var j = 0; j < folders.length; j++) {
                var notes = folders[j].notes();
                for (var k = 0; k < notes.length; k++) {
                    if (notes[k].id() === noteID) {
                        var note = notes[k];
                        var mod = note.modificationDate();
                        return JSON.stringify({
                            id: note.id(),
                            name: note.name(),
                            body: note.body(),
                            folderID: folders[j].id(),
                            modified: mod ? mod.toISOString() : null
                        });
                    }
                }
            }
        }
        return JSON.stringify({ error: 'note not found' });
    }
    """

    private static let createNoteScript = """
    function run(argv) {
        var Notes = Application('Notes');
        var folderID = argv[0];
        var title = argv[1];
        var body = argv[2];

        var targetFolder = null;
        if (folderID) {
            var accounts = Notes.accounts();
            for (var i = 0; i < accounts.length; i++) {
                var folders = accounts[i].folders();
                for (var j = 0; j < folders.length; j++) {
                    if (folders[j].id() === folderID) {
                        targetFolder = folders[j];
                        break;
                    }
                }
                if (targetFolder) break;
            }
        }
        if (!targetFolder) {
            targetFolder = Notes.defaultAccount().defaultFolder();
        }

        var newNote = Notes.Note({ name: title, body: body });
        targetFolder.notes.push(newNote);
        return JSON.stringify({ id: newNote.id(), name: newNote.name(), body: newNote.body(), folderID: targetFolder.id(), modified: null });
    }
    """
}

// MARK: - Models

struct AppleNotesFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct AppleNotesNote: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let body: String?
    let folderID: String
    let modified: Date?
}

enum AppleNotesError: LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return message
        }
    }
}
