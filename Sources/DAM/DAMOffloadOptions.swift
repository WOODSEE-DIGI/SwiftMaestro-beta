import Foundation

// MARK: - Offload options

/// Configuration for a MaestroDAM media offload: copies files from a source
/// (typically a camera card or external drive) to a primary destination and an
/// optional backup destination, verifies integrity with SHA-256, renames files
/// according to a template, and optionally imports the primary copies into the
/// catalog.
struct DAMOffloadOptions: Sendable {
    var sourceURL: URL?
    var primaryDestinationURL: URL?
    var backupDestinationURL: URL?

    /// Relative subfolder path under the destination, e.g. "{date}" or
    /// "{date}/{camera}". Empty means copy directly into the destination root.
    var subfolderTemplate: String = "{date}"

    /// Filename template, e.g. "{original}", "{seq}_{name}.{ext}",
    /// "{date}_{seq}_{camera}.{ext}".
    var filenameTemplate: String = "{original}"

    var sequenceStart: Int = 1
    var sequencePadding: Int = 4

    var verifyChecksums: Bool = true
    var preserveFolderStructure: Bool = false
    var importIntoCatalog: Bool = true
    var ejectSourceWhenDone: Bool = false

    /// True when both a source and primary destination have been chosen.
    var isValid: Bool {
        sourceURL != nil && primaryDestinationURL != nil
    }
}

// MARK: - Offload result

/// Outcome of an offload operation.
struct DAMOffloadResult: Sendable {
    var copied: Int = 0
    var failed: [(source: URL, error: String)] = []
    var imported: Int = 0
    var primaryURL: URL?
    var backupURL: URL?

    var succeeded: Bool { failed.isEmpty }
}

// MARK: - Offload progress

/// Snapshot of offload progress, safe to publish to the UI.
struct DAMOffloadProgress: Sendable {
    var currentFile: String = ""
    var completed: Int = 0
    var total: Int = 0
    var phase: Phase = .scanning

    enum Phase: String, Sendable {
        case scanning = "Scanning"
        case copying = "Copying"
        case verifying = "Verifying"
        case importing = "Importing"
        case ejecting = "Ejecting"
        case finished = "Finished"
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}
