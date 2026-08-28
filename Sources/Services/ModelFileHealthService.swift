import Foundation

// MARK: - Model file health

/// Validates and repairs the on-disk metadata files for a locally-installed model.
///
/// mlx-swift-lm needs more than just `.safetensors` weights to load a model: the
/// tokenizer, chat template, processor config (for VLMs), and model config all
/// have to be present and consistent. This service checks a model's local
/// directory against a manifest derived from the model type, and can pull any
/// missing files from the model's Hugging Face source repo so models are
/// automatically wired up correctly.
enum ModelFileHealthService {

    /// A file that should be present for a model to be considered healthy.
    struct Requirement: Sendable {
        let filename: String
        /// If true, the model cannot be loaded without this file.
        let isRequired: Bool
        /// True for large weight files (not downloaded by the metadata repair path).
        let isWeight: Bool
    }

    /// Metadata/template files that are cheap to download and should always be
    /// present, regardless of whether the model is vision or text-only.
    private static let baseMetadataFiles: [Requirement] = [
        .init(filename: "config.json", isRequired: true, isWeight: false),
        .init(filename: "tokenizer_config.json", isRequired: true, isWeight: false),
        .init(filename: "tokenizer.json", isRequired: true, isWeight: false),
        .init(filename: "generation_config.json", isRequired: false, isWeight: false),
        .init(filename: "chat_template.jinja", isRequired: false, isWeight: false),
        .init(filename: "README.md", isRequired: false, isWeight: false),
        .init(filename: ".gitattributes", isRequired: false, isWeight: false),
    ]

    /// Vision models need processor configuration so the VLM processor can be
    /// instantiated. Both `processor_config.json` and the older
    /// `preprocessor_config.json` names appear in the wild; either one is
    /// sufficient, and we prefer `processor_config.json` when repairing.
    private static let visionMetadataFiles: [Requirement] = [
        .init(filename: "processor_config.json", isRequired: true, isWeight: false),
        .init(filename: "preprocessor_config.json", isRequired: true, isWeight: false),
    ]

    /// Weight-index files that prove the model is not just an empty directory.
    private static let weightIndexFiles: [Requirement] = [
        .init(filename: "model.safetensors.index.json", isRequired: false, isWeight: true),
        .init(filename: "model-00001-of-00001.safetensors", isRequired: false, isWeight: true),
    ]

    /// All requirements for a given model.
    static func requirements(for model: MaestroModel) -> [Requirement] {
        var reqs = baseMetadataFiles
        if model.isVision {
            reqs.append(contentsOf: visionMetadataFiles)
        }
        reqs.append(contentsOf: weightIndexFiles)
        return reqs
    }

    /// Files that are missing or empty in the model's local directory.
    /// Required files are always listed; optional files are listed only when
    /// the caller also requests optional checks.
    static func missingFiles(
        for model: MaestroModel,
        includeOptional: Bool = false
    ) -> [String] {
        guard let localPath = model.localPath else { return [] }
        let directory = URL(fileURLWithPath: localPath)
        var missing: [String] = []

        let hasProcessorConfig = fileExists("processor_config.json", in: directory)
            || fileExists("preprocessor_config.json", in: directory)

        for req in requirements(for: model) {
            guard req.isRequired || includeOptional else { continue }
            // Vision models only need one of the two processor config files.
            if (req.filename == "processor_config.json" || req.filename == "preprocessor_config.json"),
               hasProcessorConfig {
                continue
            }
            if !fileExists(req.filename, in: directory) {
                missing.append(req.filename)
            }
        }
        return missing
    }

    /// True when the model directory has all required non-weight files.
    static func isMetadataComplete(for model: MaestroModel) -> Bool {
        missingFiles(for: model, includeOptional: false).isEmpty
    }

    // MARK: - Weight shard completeness

    /// True when every weight shard this model actually needs is present on
    /// disk with a non-zero size.
    ///
    /// A multi-shard checkpoint's `model.safetensors.index.json` names every
    /// shard file in its `weight_map`; this is the authoritative list to
    /// check against — "at least one `.safetensors` file exists somewhere in
    /// the directory" (the old `MaestroModel.hasLocalWeights` check) is not
    /// enough. An interrupted download can leave some shards present and
    /// others missing; loading that partial weight set doesn't throw a
    /// catchable Swift error — mlx-swift-lm's `Module.update(modules:)` hits
    /// an internal `try!` and crashes the whole app with
    /// `UpdateError.mismatchedContainers`. This is checked BEFORE attempting
    /// to load, so an incomplete download surfaces as a normal error/UI state
    /// instead of a fatal crash.
    static func weightsAreComplete(for model: MaestroModel) -> Bool {
        missingWeightShards(for: model).isEmpty
    }

    /// The shard filenames (relative to the model directory) that this
    /// checkpoint needs but that are missing or zero-length on disk. Empty
    /// when the checkpoint is a single-file (`model.safetensors` /
    /// `model-00001-of-00001.safetensors`) model.
    ///
    /// Prefers `model.safetensors.index.json`'s `weight_map` when present
    /// (the authoritative source), but does NOT require it: an interrupted
    /// download can die before the index file itself is ever written, and
    /// that's exactly the real-world case that caused a crash — 2 of 3 shards
    /// present, index.json missing entirely, and the OLD fallback here (just
    /// checking "does at least one .safetensors file exist") wrongly reported
    /// that as complete. HuggingFace's sharded-safetensors filenames are
    /// self-describing (`model-00002-of-00003.safetensors`), so when the
    /// index is missing this parses the total shard count directly out of
    /// whatever shard filenames ARE present and checks all of them exist.
    static func missingWeightShards(for model: MaestroModel) -> [String] {
        guard let localPath = model.localPath else { return ["(no local path)"] }
        let directory = URL(fileURLWithPath: localPath)
        let fm = FileManager.default

        // Self-heal a STALE upstream index before trusting its shard list:
        // some mlx-community repos ship an index.json carried over from a
        // different variant (production: Qwen3-VL-8B-Instruct-4bit's index
        // pointed at 4 shards/17.5 GB from the unquantized source repo while
        // shipping 2 four-bit shards/5.76 GB — a phantom "incomplete" state
        // no amount of re-downloading could ever fix).
        _ = repairStaleWeightIndexIfNeeded(in: directory)

        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            let shardNames = Set(weightMap.values)
            return shardNames
                .filter { !fileExists($0, in: directory) }
                .sorted()
        }

        // No index — single-shard checkpoints are common (small models).
        if fileExists("model.safetensors", in: directory)
            || fileExists("model-00001-of-00001.safetensors", in: directory) {
            return []
        }

        // No index, but the directory may still contain multi-shard files
        // named `model-XXXXX-of-YYYYY.safetensors` — that pattern is
        // self-describing, so derive the expected shard set from it directly
        // rather than trusting the (possibly also-missing) index file.
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ["(could not enumerate directory)"] }

        var anyShardFound = false
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            anyShardFound = true
            if let (_, total, digits) = parseShardName(fileURL.lastPathComponent) {
                return (1...total)
                    .map { shardFilename(index: $0, total: total, digits: digits) }
                    .filter { !fileExists($0, in: directory) }
                    .sorted()
            }
        }

        // At least one .safetensors file exists but it doesn't match the
        // recognized sharded-naming pattern (an unfamiliar-but-plausible
        // layout) — treat leniently rather than flagging it as broken.
        return anyShardFound ? [] : ["(no .safetensors files found)"]
    }

    // MARK: - Stale index repair

    /// Detect and repair a STALE `model.safetensors.index.json`: an index
    /// whose `weight_map` names shards that will never exist in this download
    /// (carried over from a different repo variant upstream). Detection is
    /// deliberately strict — ALL three must hold:
    ///   1. ZERO of the index's shard files exist on disk, AND
    ///   2. OTHER `.safetensors` files DO exist on disk, AND
    ///   3. those files form COMPLETE self-describing shard sets
    ///      (every `model-XXXXX-of-YYYYY` group has all YYY shards) — so a
    ///      half-downloaded model is never blessed as complete.
    /// Repair rebuilds `weight_map` from the on-disk shards' safetensors
    /// headers and rewrites the index (upstream file backed up alongside).
    /// This heals mlx-swift-lm loading too, which reads the same index.
    /// - Returns: true when a repair was performed.
    @discardableResult
    static func repairStaleWeightIndexIfNeeded(in directory: URL) -> Bool {
        let fm = FileManager.default
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard fm.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String],
              !weightMap.isEmpty else { return false }

        let indexShards = Set(weightMap.values)
        guard indexShards.allSatisfy({ !fileExists($0, in: directory) }) else {
            return false  // at least one indexed shard exists → normal partial download
        }
        guard let onDisk = try? fm.contentsOfDirectory(atPath: directory.path)
            .filter({ $0.hasSuffix(".safetensors") }), !onDisk.isEmpty else { return false }

        // Safety: on-disk shards must form complete self-describing sets.
        var groups: [String: (total: Int, present: Set<Int>)] = [:]
        for file in onDisk {
            guard let (index, total, digits) = parseShardName(file) else { return false }
            let key = "\(total)-\(digits)"
            var group = groups[key] ?? (total, [])
            group.present.insert(index)
            groups[key] = group
        }
        for (_, group) in groups {
            guard group.present.count == group.total,
                  (1...group.total).allSatisfy(group.present.contains) else { return false }
        }

        // Rebuild weight_map from the shards' own headers.
        var newMap: [String: String] = [:]
        var totalBytes: Int64 = 0
        for file in onDisk {
            let url = directory.appendingPathComponent(file)
            guard let names = safetensorsTensorNames(url) else { return false }
            for name in names { newMap[name] = file }
            totalBytes += Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
        guard !newMap.isEmpty else { return false }

        let backup = directory.appendingPathComponent("model.safetensors.index.json.upstream-broken.bak")
        try? fm.removeItem(at: backup)
        guard let _ = try? fm.moveItem(at: indexURL, to: backup) else { return false }
        let out: [String: Any] = ["metadata": ["total_size": totalBytes], "weight_map": newMap]
        guard let outData = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try outData.write(to: indexURL, options: .atomic)
        } catch {
            // Restore the upstream file on write failure so we never leave no index.
            try? fm.moveItem(at: backup, to: indexURL)
            return false
        }
        NSLog("[ModelFileHealth] repaired STALE weight index in %@: %d phantom shard(s) replaced by %d real file(s), %d tensors, %lld bytes",
              directory.lastPathComponent, indexShards.count, onDisk.count, newMap.count, totalBytes)
        return true
    }

    /// Read the tensor names from a safetensors file's header (8-byte LE
    /// length prefix + JSON object). Returns nil on any parse failure.
    static func safetensorsTensorNames(_ url: URL) -> Set<String>? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let lenData = try? handle.read(upToCount: 8), lenData.count == 8 else { return nil }
        let headerLen = lenData.withUnsafeBytes { $0.load(as: UInt64.self) }
        guard headerLen > 0, headerLen < 500_000_000,
              let headerData = try? handle.read(upToCount: Int(headerLen)),
              let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return nil }
        return Set(json.keys.filter { $0 != "__metadata__" })
    }

    /// Parses `model-00002-of-00003.safetensors` (any prefix before the shard
    /// numbers, any zero-padding width) into (index: 2, total: 3, digits: 5).
    private static func parseShardName(_ filename: String) -> (index: Int, total: Int, digits: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"-(\d+)-of-(\d+)\.safetensors$"#) else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let indexRange = Range(match.range(at: 1), in: filename),
              let totalRange = Range(match.range(at: 2), in: filename),
              let index = Int(filename[indexRange]),
              let total = Int(filename[totalRange])
        else { return nil }
        return (index, total, filename[indexRange].count)
    }

    /// Rebuilds a shard filename matching the naming convention of the file
    /// `parseShardName` was derived from (`model-`, zero-padding width, `-of-`).
    private static func shardFilename(index: Int, total: Int, digits: Int) -> String {
        let indexStr = String(format: "%0\(digits)d", index)
        let totalStr = String(format: "%0\(digits)d", total)
        return "model-\(indexStr)-of-\(totalStr).safetensors"
    }

    /// Download any missing metadata files from the model's Hugging Face repo.
    /// Weight files are never downloaded by this repair path; use
    /// `MLXInferenceEngine.downloadModel` for a full weight download.
    static func repairMetadata(for model: MaestroModel) async throws {
        guard let localPath = model.localPath else {
            throw HealthError.noLocalPath
        }
        let directory = URL(fileURLWithPath: localPath)
        let missing = missingFiles(for: model, includeOptional: true)
            .filter { !$0.hasSuffix(".safetensors") && $0 != "model.safetensors.index.json" }

        guard !missing.isEmpty else { return }

        let token = SecretsStore.resolveValue(name: "HUGGINGFACE_TOKEN", currentProject: "SwiftMaestro")
        for filename in missing {
            try await downloadSingleMetadataFile(
                filename: filename,
                repoID: model.huggingFaceID,
                directory: directory,
                token: token
            )

            // Some vision repos use the older `preprocessor_config.json` name instead
            // of `processor_config.json`. If the preferred name wasn't fetched, try the
            // fallback before giving up.
            if filename == "processor_config.json",
               !fileExists("processor_config.json", in: directory),
               !fileExists("preprocessor_config.json", in: directory) {
                try await downloadSingleMetadataFile(
                    filename: "preprocessor_config.json",
                    repoID: model.huggingFaceID,
                    directory: directory,
                    token: token
                )
            }
        }
    }

    private static func downloadSingleMetadataFile(
        filename: String,
        repoID: String,
        directory: URL,
        token: String?
    ) async throws {
        // Never overwrite a file that already exists locally, even if its size
        // differs from the repo copy. This keeps locally-quantized or patched
        // configs from being clobbered by upstream metadata.
        guard !isPresent(filename, in: directory) else {
            NSLog("[ModelFileHealthService] skipping %@: already present at %@", filename, directory.path)
            return
        }
        _ = try await HuggingFaceDownloadService.shared.download(
            repoID: repoID,
            localDir: directory.path,
            allowPatterns: [filename],
            token: token
        )
    }

    /// Repair wrapper that catches and logs errors without throwing, suitable
    /// for opportunistic calls during model loading.
    @discardableResult
    static func repairMetadataIfNeeded(for model: MaestroModel) async -> Bool {
        do {
            try await repairMetadata(for: model)
            return true
        } catch {
            NSLog("[ModelFileHealthService] metadata repair failed for \(model.id): \(error)")
            return false
        }
    }

    /// Install a tools-enabled chat template overlay for curated models whose
    /// stock template has no `tools` block (e.g. DeepSeek-Coder-V2-Lite —
    /// tool-call trained, but its 459-char stock template is pure
    /// User:/Assistant: turns, so tool schemas were silently dropped from the
    /// prompt). swift-transformers prefers a `chat_template.jinja` file over
    /// the config-embedded template, so writing the file is all it takes.
    ///
    /// Only installs when the file is missing — a user-edited or newer
    /// upstream template is never overwritten.
    static func repairChatTemplateIfNeeded(for model: MaestroModel) {
        guard let overlay = ChatTemplateOverlays.overlay(forModelID: model.id),
              let localPath = model.localPath else { return }
        let dest = URL(fileURLWithPath: localPath)
            .appendingPathComponent("chat_template.jinja")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            try overlay.write(to: dest, atomically: true, encoding: .utf8)
            NSLog("[ModelFileHealthService] installed tools-enabled chat template for \(model.id)")
        } catch {
            NSLog("[ModelFileHealthService] chat template install failed for \(model.id): \(error)")
        }
    }

    // MARK: - Helpers

    private static func fileExists(_ filename: String, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int
        else { return false }
        return size > 0
    }

    /// True when a file entry exists at the destination, regardless of size.
    private static func isPresent(_ filename: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }

    enum HealthError: LocalizedError {
        case noLocalPath

        var errorDescription: String? {
            switch self {
            case .noLocalPath:
                return "Model has no local path to repair."
            }
        }
    }
}

