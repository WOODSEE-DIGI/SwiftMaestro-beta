import Foundation

/// Describes a model that can be bundled inside the SwiftMaestro app bundle and
/// installed into the canonical user-writable location on first launch.
struct BundledModelDescriptor: Sendable {
    /// Human-readable name for logs.
    let name: String
    /// Relative path inside `SwiftMaestro.app/Contents/Resources/models/` where
    /// the model ships in the app bundle.
    let bundleSubpath: String
    /// Absolute path in the user's home directory where the model should live.
    let installedURL: URL
    /// Version key used in UserDefaults to track whether this model is installed.
    let versionKey: String
    /// Current version. Bump when the bundled checkpoint changes.
    let currentVersion: String
    /// Closure that returns true when the destination directory already contains
    /// a usable model. For MLX models this is a `.safetensors` file; for WhisperKit
    /// it is a `.mlmodelc` bundle.
    let isInstalled: @Sendable (URL) -> Bool
}

/// Installs any models bundled inside the SwiftMaestro app bundle into their
/// canonical user-writable locations on first launch.
///
/// This makes both the "full" .dmg (with Gemma 4) and the "light" .dmg (with
/// Whisper only) self-contained: each model ships inside the app, then is made
/// available exactly where the rest of the app expects to find it.
@MainActor
final class BundledModelService {

    static let shared = BundledModelService()

    private let fm = FileManager.default

    /// The Gemma 4 model is only bundled in the full .dmg.
    private var gemmaModel: BundledModelDescriptor {
        let name = "gemma-4-26B-A4B-it-MLX-8bit"
        return BundledModelDescriptor(
            name: name,
            bundleSubpath: "swiftmaestro-models/\(name)",
            installedURL: SwiftMaestroPaths.modelsDir
                .appendingPathComponent("swiftmaestro-models/\(name)", isDirectory: true),
            versionKey: "bundledModel.gemma.installedVersion",
            currentVersion: "1",
            isInstalled: { url in
                FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )?.contains { item in
                    guard let fileURL = item as? URL else { return false }
                    return fileURL.pathExtension == "safetensors"
                } ?? false
            }
        )
    }

    /// The Whisper model is bundled in both full and light .dmgs.
    private var whisperModel: BundledModelDescriptor {
        let name = "openai_whisper-large-v3"
        return BundledModelDescriptor(
            name: name,
            bundleSubpath: "whisperkit/\(name)",
            installedURL: SwiftMaestroPaths.whisperKitDir
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent("\(name)", isDirectory: true),
            versionKey: "bundledModel.whisper.installedVersion",
            currentVersion: "1",
            isInstalled: { url in
                FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )?.contains { item in
                    guard let fileURL = item as? URL else { return false }
                    return fileURL.pathExtension == "mlmodelc"
                } ?? false
            }
        )
    }

    /// All models that may be bundled. Each is installed independently if present.
    private var models: [BundledModelDescriptor] {
        [gemmaModel, whisperModel]
    }

    /// URL to the bundled model directory inside the app bundle.
    private func bundledURL(for model: BundledModelDescriptor) -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.bundleSubpath, isDirectory: true)
    }

    /// True if the model directory is present in the app bundle.
    private func hasBundledModel(_ model: BundledModelDescriptor) -> Bool {
        guard let url = bundledURL(for: model) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True if the model is already installed in the user's model location.
    private func isInstalled(_ model: BundledModelDescriptor) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: model.installedURL.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return model.isInstalled(model.installedURL)
    }

    /// Install all bundled models that are not already present. Returns true for
    /// each model that is immediately available (hardlinked or already present).
    /// Models that require a background copy return false, but a copy is started.
    func installAllIfNeeded() async -> [String: Bool] {
        var results: [String: Bool] = [:]
        for model in models {
            results[model.name] = await installIfNeeded(model: model)
        }
        return results
    }

    /// Legacy convenience method used by the app launch sequence.
    func installIfNeeded() async -> Bool {
        let results = await installAllIfNeeded()
        return results.values.contains(true)
    }

    private func installIfNeeded(model: BundledModelDescriptor) async -> Bool {
        guard hasBundledModel(model) else {
            NSLog("[BundledModel] No bundled %@ found in app bundle", model.name)
            return false
        }

        let installedVersion = UserDefaults.standard.string(forKey: model.versionKey)
        if isInstalled(model), installedVersion == model.currentVersion {
            NSLog("[BundledModel] %@ already installed at %@", model.name, model.installedURL.path)
            return true
        }

        guard let source = bundledURL(for: model) else { return false }
        let destination = model.installedURL

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            NSLog("[BundledModel] Failed to create parent directory for %@: %@",
                  model.name, error.localizedDescription)
            return false
        }

        // If a partial or stale installation exists, remove it first.
        if fm.fileExists(atPath: destination.path) {
            do {
                try fm.removeItem(at: destination)
            } catch {
                NSLog("[BundledModel] Failed to remove stale %@ install: %@",
                      model.name, error.localizedDescription)
                return false
            }
        }

        NSLog("[BundledModel] Installing %@ -> %@", source.path, destination.path)

        // Try the fast path: hardlink every file. This shares inodes when the app
        // bundle and destination are on the same APFS volume.
        let hardlinked = await hardlinkContents(from: source, to: destination)
        if hardlinked {
            UserDefaults.standard.set(model.currentVersion, forKey: model.versionKey)
            NSLog("[BundledModel] %@ installed via hardlinks", model.name)
            return true
        }

        // Fallback: copy in the background. This is slow for large models but works
        // across filesystems or when the app bundle is read-only.
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                try await self.copyContents(from: source, to: destination)
                await MainActor.run {
                    UserDefaults.standard.set(model.currentVersion, forKey: model.versionKey)
                }
                NSLog("[BundledModel] %@ installed via copy", model.name)
                NotificationCenter.default.post(name: .bundledModelInstalled, object: nil)
            } catch {
                NSLog("[BundledModel] %@ copy failed: %@", model.name, error.localizedDescription)
            }
        }

        return false
    }

    /// Recursively hardlink all files from `source` to `destination`. Returns true
    /// only if every file was successfully hardlinked.
    private func hardlinkContents(from source: URL, to destination: URL) async -> Bool {
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for item in contents {
                let name = item.lastPathComponent
                let dstItem = destination.appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let childOK = await hardlinkContents(from: item, to: dstItem)
                    if !childOK { return false }
                } else {
                    do {
                        try fm.linkItem(at: item, to: dstItem)
                    } catch {
                        NSLog("[BundledModel] Hardlink failed for %@: %@", name, error.localizedDescription)
                        return false
                    }
                }
            }
            return true
        } catch {
            NSLog("[BundledModel] Hardlink tree failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Recursively copy all files from `source` to `destination`. Large files are
    /// copied as a single operation; this is only used as a fallback.
    private func copyContents(from source: URL, to destination: URL) async throws {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let dstItem = destination.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try await copyContents(from: item, to: dstItem)
            } else {
                try fm.copyItem(at: item, to: dstItem)
            }
        }
    }
}

extension Notification.Name {
    static let bundledModelInstalled = Notification.Name("com.woodseedigi.swiftmaestro.bundledModelInstalled")
}
