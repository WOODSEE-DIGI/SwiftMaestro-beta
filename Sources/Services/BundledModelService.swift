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
///
/// Deliberately NON-isolated (no @MainActor): first-run installation
/// enumerates and hardlinks (or copies) multi-GB model trees — synchronous
/// file work that used to run on the main thread during the launch `.task`
/// and beachball the app while the welcome sheet was visible. All state is
/// immutable or in UserDefaults, so the class is Sendable.
final class BundledModelService: @unchecked Sendable {

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

    /// True when this launch will actually install a model (a bundled model is
    /// present that is missing or stale). Cheap: directory-exists checks plus
    /// an enumerator that stops at the first weight file. Used by
    /// `SetupProgressService.plan()` before any window appears.
    var needsInstall: Bool {
        models.contains { model in
            hasBundledModel(model)
                && !(isInstalled(model)
                     && UserDefaults.standard.string(forKey: model.versionKey) == model.currentVersion)
        }
    }

    /// Install all bundled models that are not already present. Returns true for
    /// each model that is immediately available (hardlinked, copied, or already
    /// present).
    ///
    /// The copy fallback (app on a different volume than the model root, e.g.
    /// running straight from the DMG) is AWAITED, not fire-and-forget: the work
    /// runs off the main thread now, so there is no beachball to avoid, and
    /// awaiting it keeps the launch sequence's eager model-load honest.
    func installAllIfNeeded(progress: SetupReporter? = nil) async -> [String: Bool] {
        var results: [String: Bool] = [:]
        var stepBegan = false
        for model in models {
            if !stepBegan, hasBundledModel(model),
               !(isInstalled(model)
                 && UserDefaults.standard.string(forKey: model.versionKey) == model.currentVersion) {
                await progress?.begin(SetupStepID.bundledModels, detail: "Preparing models…")
                stepBegan = true
            }
            results[model.name] = await installIfNeeded(model: model, progress: progress)
        }
        if stepBegan {
            let failed = results.filter { !$0.value }.map(\.key)
            if failed.isEmpty {
                await progress?.finish(SetupStepID.bundledModels, .done, detail: "Models ready")
            } else {
                await progress?.finish(SetupStepID.bundledModels,
                                       .failed(failed.joined(separator: ", ")),
                                       detail: "Failed: \(failed.joined(separator: ", "))")
            }
        }
        return results
    }

    /// Convenience method used by the app launch sequence.
    func installIfNeeded(progress: SetupReporter? = nil) async -> Bool {
        let results = await installAllIfNeeded(progress: progress)
        return results.values.contains(true)
    }

    private func installIfNeeded(model: BundledModelDescriptor, progress: SetupReporter?) async -> Bool {
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

        await progress?.update(SetupStepID.bundledModels, detail: "Preparing \(model.name)…")

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

        // Flatten the source tree once so progress can name the exact file
        // being linked/copied with an "x of y" count.
        let files = allFiles(under: source)

        // Try the fast path: hardlink every file. This shares inodes when the app
        // bundle and destination are on the same APFS volume.
        let hardlinked = await linkContents(files, from: source, to: destination,
                                            modelName: model.name, progress: progress)
        if hardlinked {
            UserDefaults.standard.set(model.currentVersion, forKey: model.versionKey)
            NSLog("[BundledModel] %@ installed via hardlinks", model.name)
            return true
        }

        // Fallback: copy. Slow for large models (multi-GB when running from the
        // DMG, i.e. a different filesystem) but works everywhere. Awaited — see
        // installAllIfNeeded's doc comment.
        do {
            await progress?.update(SetupStepID.bundledModels,
                                   detail: "Copying \(model.name) — this can take several minutes…")
            try await copyContents(files, from: source, to: destination,
                                   modelName: model.name, progress: progress)
            UserDefaults.standard.set(model.currentVersion, forKey: model.versionKey)
            NSLog("[BundledModel] %@ installed via copy", model.name)
            NotificationCenter.default.post(name: .bundledModelInstalled, object: nil)
            return true
        } catch {
            NSLog("[BundledModel] %@ copy failed: %@", model.name, error.localizedDescription)
            return false
        }
    }

    /// All regular files under `root` (directories are recreated implicitly by
    /// the link/copy loops via per-file parent creation).
    private func allFiles(under root: URL) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append(url)
        }
        return files
    }

    /// Hardlink every file, preserving the relative directory structure.
    /// Returns true only if every file was successfully hardlinked.
    private func linkContents(_ files: [URL], from source: URL, to destination: URL,
                              modelName: String, progress: SetupReporter?) async -> Bool {
        let total = files.count
        for (index, file) in files.enumerated() {
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let dstItem = destination.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: dstItem.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.linkItem(at: file, to: dstItem)
            } catch {
                NSLog("[BundledModel] Hardlink failed for %@: %@", relative, error.localizedDescription)
                return false
            }
            // Throttle MainActor hops — every file for small trees, every 25
            // for large ones.
            if index % 25 == 0 || index == total - 1 {
                await progress?.update(SetupStepID.bundledModels,
                                       detail: "Linking \(modelName): \(file.lastPathComponent) (\(index + 1) of \(total))",
                                       progress: total > 0 ? Double(index + 1) / Double(total) : nil)
            }
        }
        return true
    }

    /// Copy every file, preserving the relative directory structure. Only used
    /// as a fallback when hardlinking is impossible (different filesystems).
    private func copyContents(_ files: [URL], from source: URL, to destination: URL,
                              modelName: String, progress: SetupReporter?) async throws {
        let total = files.count
        for (index, file) in files.enumerated() {
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let dstItem = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: dstItem.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: dstItem)
            await progress?.update(SetupStepID.bundledModels,
                                   detail: "Copying \(modelName): \(file.lastPathComponent) (\(index + 1) of \(total))",
                                   progress: total > 0 ? Double(index + 1) / Double(total) : nil)
        }
    }
}

extension Notification.Name {
    static let bundledModelInstalled = Notification.Name("com.woodseedigi.swiftmaestro.bundledModelInstalled")
}
