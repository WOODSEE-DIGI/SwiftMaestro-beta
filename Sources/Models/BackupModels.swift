import Foundation

// MARK: - Backup Destination

/// Where backup data is stored. Supports any S3-compatible provider, SFTP, or local path.
struct BackupDestination: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: Kind
    var isEnabled: Bool

    enum Kind: Codable, Hashable, Sendable {
        /// S3-compatible object storage (Onidel, Hetzner, B2, AWS, etc.)
        case s3(S3Config)
        /// SSH/SFTP server
        case sftp(SFTPConfig)
        /// Local directory (for local-only backups)
        case local(LocalConfig)
    }

    struct S3Config: Codable, Hashable, Sendable {
        var endpoint: String          // e.g. "https://s3.ap-southeast-2.onidel.cloud"
        var bucket: String            // e.g. "woodsee-backups"
        var accessKeyID: String       // stored in Keychain, not here
        var secretAccessKey: String   // stored in Keychain, not here
        var region: String            // e.g. "ap-southeast-2"
        var usePathStyle: Bool        // true for most S3-compatible providers
    }

    struct SFTPConfig: Codable, Hashable, Sendable {
        var host: String              // e.g. "216.176.239.20"
        var port: Int                 // default 22
        var username: String          // e.g. "root"
        var keyPath: String           // e.g. "~/.ssh/id_ed25519"
        var repositoryPath: String    // e.g. "/mnt/backup/repo"
    }

    struct LocalConfig: Codable, Hashable, Sendable {
        var path: String              // e.g. "/Volumes/External/backup-repo"
    }

    init(id: UUID = UUID(), name: String, kind: Kind, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

// MARK: - Backup Job

/// A set of directories to back up to a destination with a schedule.
struct BackupJob: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sourcePaths: [String]        // directories to back up
    var excludePatterns: [String]    // glob patterns to exclude
    var destinationID: UUID          // references BackupDestination.id
    var schedule: Schedule
    var isEnabled: Bool
    var lastRunDate: Date?
    var lastSnapshotID: String?
    var createdAt: Date

    enum Schedule: Codable, Hashable, Sendable {
        case manual
        case hourly
        case daily(hour: Int, minute: Int)
        case weekly(weekday: Int, hour: Int, minute: Int) // weekday: 1=Sun..7=Sat
        case custom(intervalSeconds: Int)

        var displayDescription: String {
            switch self {
            case .manual: return "Manual only"
            case .hourly: return "Every hour"
            case .daily(let h, let m): return "Daily at \(String(format: "%02d:%02d", h, m))"
            case .weekly(let d, let h, let m): return "\(weekdayName(d)) at \(String(format: "%02d:%02d", h, m))"
            case .custom(let s): return "Every \(s / 3600)h"
            }
        }

        private func weekdayName(_ d: Int) -> String {
            ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][d % 7]
        }
    }

    init(id: UUID = UUID(), name: String, sourcePaths: [String] = [], excludePatterns: [String] = BackupJob.defaultExcludes, destinationID: UUID, schedule: Schedule = .manual, isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourcePaths = sourcePaths
        self.excludePatterns = excludePatterns
        self.destinationID = destinationID
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    static let defaultExcludes = [
        "node_modules", ".cache", "DerivedData", "__pycache__",
        "*.pyc", ".DS_Store", "*.tmp", "*.swp", "Thumbs.db",
        ".Trash", "Library/Caches"
    ]
}

// MARK: - Backup Log Entry

/// Record of a backup run.
struct BackupLogEntry: Identifiable, Codable, Sendable {
    var id: UUID
    var jobID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var filesScanned: Int?
    var totalSizeBytes: Int64?
    var uploadedBytes: Int64?
    var snapshotID: String?
    var errorMessage: String?
    var checksumVerified: Bool?
    var checksumResult: ChecksumResult?

    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }

    enum ChecksumResult: String, Codable, Sendable {
        case passed
        case failed
        case pending
    }

    var duration: TimeInterval? {
        guard let finished = finishedAt else { return nil }
        return finished.timeIntervalSince(startedAt)
    }

    init(id: UUID = UUID(), jobID: UUID, startedAt: Date = Date()) {
        self.id = id
        self.jobID = jobID
        self.startedAt = startedAt
        self.status = .running
    }
}

// MARK: - Backup State

/// Current state of a running backup.
struct BackupState: Sendable {
    var jobID: UUID?
    var phase: Phase = .idle
    var filesScanned: Int = 0
    var totalFiles: Int = 0
    var bytesUploaded: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String = ""
    var speed: Double = 0 // bytes per second

    enum Phase: String, Sendable {
        case idle
        case scanning
        case uploading
        case pruning
        case finished
    }

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesUploaded) / Double(totalBytes)
    }
}
