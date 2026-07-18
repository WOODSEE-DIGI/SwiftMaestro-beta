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
        let fm = FileManager.default
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

    /// The shard filenames (relative to the model directory) that
    /// `model.safetensors.index.json` declares but that are missing or
    /// zero-length on disk. Empty when the checkpoint is a single-file
    /// (`model.safetensors` / `model-00001-of-00001.safetensors`) model, or
    /// when there's no index to validate against and at least one
    /// `.safetensors` file is present (an unrecognized-but-plausible layout —
    /// treated leniently rather than as a false failure).
    static func missingWeightShards(for model: MaestroModel) -> [String] {
        guard let localPath = model.localPath else { return ["(no local path)"] }
        let directory = URL(fileURLWithPath: localPath)
        let fm = FileManager.default

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

        // No index and no recognized single-shard name: fall back to the old
        // lenient check (at least one .safetensors file anywhere) rather than
        // flagging an unfamiliar-but-valid layout as broken.
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ["(could not enumerate directory)"] }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            return []
        }
        return ["(no .safetensors files found)"]
    }

    /// Download any missing metadata files from the model's Hugging Face repo.
    /// Weight files are never downloaded by this repair path; use
    /// `MLXInferenceEngine.downloadModel` for a full weight download.
    static func repairMetadata(for model: MaestroModel) async throws {
        guard let localPath = model.localPath else {
            throw HealthError.noLocalPath
        }
        let directory = URL(fileURLWithPath: localPath)
        var missing = missingFiles(for: model, includeOptional: true)
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
        try await HuggingFaceDownloadService.shared.download(
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

