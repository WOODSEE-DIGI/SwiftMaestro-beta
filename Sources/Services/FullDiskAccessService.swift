import AppKit
import Foundation

// MARK: - Full Disk Access (macOS TCC)

/// Detects and surfaces the real macOS-level Full Disk Access grant
/// (TCC `kTCCServiceSystemPolicyAllFiles`).
///
/// There is no API to request Full Disk Access — only the user can grant it,
/// in System Settings → Privacy & Security → Full Disk Access. All the app
/// can do is detect the grant and deep-link to the right pane. macOS applies
/// the grant at process launch, so the app must be relaunched after the
/// toggle changes.
///
/// This is a separate layer from the in-app "unrestricted file access"
/// toggle in Settings → Context: that toggle only bypasses SwiftMaestro's own
/// Authorized Folders list. TCC-protected locations (Mail, Messages, Safari,
/// the TCC database, other apps' containers) need the system grant regardless
/// of the in-app toggle.
enum FullDiskAccessService {

    /// A path that always exists and is always gated behind Full Disk Access.
    /// The TCC database itself is the canonical probe: without FDA, opening
    /// it fails with EPERM/NSFileReadNoPermission.
    private static var probeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// Whether the running process currently holds Full Disk Access.
    ///
    /// Probes the TCC database with a 1-byte read — success means the grant
    /// is active. Cheap and side-effect free; safe to call on Settings appear
    /// or from a Recheck button.
    static func isGranted() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: probeURL) else { return false }
        defer { try? handle.close() }
        guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else { return false }
        return true
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access so the
    /// user can toggle SwiftMaestro on. (There is no programmatic grant API.)
    @MainActor
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
