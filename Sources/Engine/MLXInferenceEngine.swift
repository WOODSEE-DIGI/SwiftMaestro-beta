import Foundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Hub
import Tokenizers
import CoreImage
import SwiftMaestroKit

// MARK: - Engine State

enum EngineState: Equatable {
    case idle
    case loading(String)
    case ready(String)
    case generating
    case downloading(String)
    case error(String)
}

extension Notification.Name {
    /// Posted when the inference engine detects insufficient memory for a
    /// generation and requests the ChatViewModel to compact the context.
    static let memoryPressureCompactionNeeded = Notification.Name(
        "com.woodseedigi.swiftmaestro.memoryPressureCompactionNeeded")
}

enum EngineError: LocalizedError {
    /// The model's local directory is missing one or more weight shards
    /// declared in its `model.safetensors.index.json` (an interrupted or
    /// partial download). Loading it would otherwise crash the whole app via
    /// mlx-swift-lm's internal `Module.update(modules:)` `try!`.
    case incompleteWeights(model: String, missingShards: [String])

    /// The system does not have enough free memory to load the model right
    /// now — measured against SYSTEM-WIDE availability (which includes other
    /// logged-in user sessions' wired GPU heaps under fast user switching),
    /// not just this app's own residency budget.
    case insufficientMemory(model: String, neededGB: Int, availableGB: Int)

    var errorDescription: String? {
        switch self {
        case .incompleteWeights(let model, let missingShards):
            return "\(model)'s download is incomplete — missing \(missingShards.count) "
                + "weight file(s): \(missingShards.prefix(3).joined(separator: ", "))"
                + (missingShards.count > 3 ? ", …" : "") + ". Re-download it in Settings → Models."
        case .insufficientMemory(let model, let neededGB, let availableGB):
            return "Not enough memory to load \(model) — it needs about \(neededGB) GB free, "
                + "but only about \(availableGB) GB is available right now. Unload other "
                + "models, quit heavy apps, and check no other logged-in user account is "
                + "holding a model (fast user switching keeps that memory reserved), then "
                + "try again."
        }
    }
}

// MARK: - Generation Output

enum GenerationOutput: Sendable {
    case token(String)
    case info(tokensPerSecond: Double)
    case toolCall(name: String)
}

// MARK: - Tokenizer Loader
/// Adapter from swift-transformers tokenizer protocol to MLXLMCommon.Tokenizer.
struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads tokenizers from local model directories using swift-transformers.
struct MaestroTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(tokenizer)
    }
}

// MARK: - Hub Downloader

/// Downloads models from HuggingFace Hub using swift-transformers HubApi.
struct HFHubDownloader: MLXLMCommon.Downloader {
    let hubApi: HubApi

    init(token: String? = nil) {
        // HubApi.snapshot() internally appends "models/<org>/<repo>" to the
        // downloadBase.  modelsRoot already ends in "models/", so we must use
        // its *parent* to avoid a double-nested "models/models/..." path.
        let base = URL(fileURLWithPath: ModelCatalog.modelsRoot)
            .deletingLastPathComponent()
        self.hubApi = HubApi(downloadBase: base, hfToken: token)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let repo = Hub.Repo(id: id)
        return try await hubApi.snapshot(
            from: repo,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// Downloader that returns an already-local model directory.
/// Used for local vision models so we can pass an explicit ModelConfiguration
/// (including toolCallFormat) through the factory's configuration-aware path.
struct LocalDirectoryDownloader: MLXLMCommon.Downloader {
    let directory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        directory
    }
}

// MARK: - MLXInferenceEngine

/// Native MLX inference engine for Apple Silicon.
/// Loads models from local paths or HuggingFace Hub, runs inference on GPU.
@Observable
@MainActor
final class MLXInferenceEngine {

    // MARK: - Published state

    private(set) var state: EngineState = .idle
    /// Legacy single-download progress. Kept for OnboardingView; Settings
    /// uses ``modelDownloadProgress`` for per-model accuracy.
    private(set) var downloadProgress: Progress?
    private(set) var tokensPerSecond: Double = 0

    /// Per-model download progress (model.id → 0...1). Updated by the
    /// observation loop inside ``performDownload``. SwiftUI observes this
    /// via `@Observable`, so every tick triggers a view refresh.
    var modelDownloadProgress: [String: Double] = [:]

    // MARK: - Private

    /// Loaded model containers keyed by `model.id`. A plain dictionary (not
    /// NSCache) so residency is DETERMINISTIC: NSCache evicts at the system's
    /// discretion under memory pressure, which silently dropped a resident model
    /// and forced a slow reload-from-disk on the next switch. Eviction here is
    /// driven solely by `evictResidentToFit` against the memory budget.
    private var modelCache: [String: ModelContainer] = [:]

    /// Book-keeping for one resident (loaded) model.
    private struct ResidentModel {
        let displayName: String
        let estimatedBytes: Int
        var lastUsed: UInt64
    }
    /// Models currently held resident, keyed by `model.id`. SwiftMaestro keeps as
    /// MANY models resident as fit within `residentBudgetBytes` (90% of system RAM
    /// by default), evicting the least-recently-used only when a new load would
    /// exceed the budget. Medium models (35B, Coder, 27B) coexist for instant
    /// agent switching, while the total stays within what can be wired — exceeding
    /// it paged the 122B to ~0.5 tok/s.
    private var resident: [String: ResidentModel] = [:]
    /// Monotonic counter for LRU ordering of `resident`.
    private var lruClock: UInt64 = 0
    /// The model id of the most recent generation. Used to detect a model switch
    /// so we can drop the incoming model's prompt KV cache before reusing it —
    /// reusing a cache built before another model generated crashes (the
    /// intervening model's MLX evaluation invalidates the cached arrays).
    private var lastGenerationModelID: String?
    private let tokenizerLoader = MaestroTokenizerLoader()
    private let hubDownloader = HFHubDownloader()
    private var generateTask: Task<Void, any Error>?

    /// Serializes model downloads so only one runs at a time. Concurrent
    /// downloads cause two Python hf_download_helper processes to fight over
    /// the shared HuggingFace cache (~/.cache/huggingface) and the Python
    /// venv, corrupting each other's file transfers. Queuing ensures the
    /// first download completes before the second begins.
    private var downloadChain: Task<Void, any Error>?
    /// Mutex protecting `downloadChain` so concurrent callers of
    /// `downloadModel` don't race on the read-modify-write of the chain.
    private let downloadMutex = NSLock()
    /// Repos currently queued/in-flight, guarded by `downloadMutex`. A second
    /// `downloadModel` for the SAME repo awaits the in-flight chain instead of
    /// queueing a duplicate — production: two repair triggers for Qwen3-VL-8B
    /// queued back-to-back and each wiped the other's progress (17.5 GB from
    /// scratch, repeatedly).
    private var queuedDownloadRepos = Set<String>()

    /// Client-side MCP tool source. Set during app launch. When present (and the
    /// model supports tools), discovered MCP tools join the same agentic loop as
    /// the native tools.
    var mcpService: MCPClientService?

    /// Per-agent prompt KV caches, keyed by `sessionKey + "::" + model.id`. The
    /// big fixed `[system + tools]` prefix dominates prefill; keeping its KV per
    /// agent lets concurrent agents each reuse their own prefix instead of
    /// fighting over one shared slot. Looked up on the MainActor; each round
    /// captures its own `PromptCache` reference for use inside the container's
    /// isolated closure.
    private var promptCaches: [String: PromptCache] = [:]

    /// Single cache used only by the legacy `generate(messages:model:)` path
    /// (no current callers); the live per-agent path uses `promptCaches`.
    private let legacyPromptCache = PromptCache()

    /// Fetch (or create) the prompt cache for a session key.
    private func cache(forSession key: String) -> PromptCache {
        if let existing = promptCaches[key] { return existing }
        let fresh = PromptCache()
        promptCaches[key] = fresh
        return fresh
    }

    init() {
        // Scale the GPU buffer cache to the machine instead of a fixed 20MB.
        // The old 20MB cap forced the 122B's large MoE expert buffers to be
        // freed + reallocated every token, collapsing decode to ~0.5 tok/s;
        // a machine-scaled cache lets them recycle, matching the ~40 tok/s the
        // same model reaches under mlx_lm's default memory settings. Capped at
        // 50% of recommended to leave headroom for KV cache + activations and
        // avoid hitting OS memory pressure (spinning beach ball).
        if let workingSet = MLX.GPU.maxRecommendedWorkingSetBytes() {
            MLX.Memory.cacheLimit = workingSet / 2
        }

        // Graph compilation is kept ENABLED for kernel fusion on MoE ops
        // (compiledSiluProduct, weightedExpertSum in SwitchLayers.swift). The
        // previous crash on model switch happened because
        // MLX.Memory.clearCache() freed GPU buffers but left stale compiled
        // graphs referencing them; the fix is to ALSO clear the compiled graph
        // cache (via mlx_detail_compile_clear_cache) at every point where we
        // clear the buffer cache. See clearMLXCaches().
        compile(enable: true)
    }

    // MARK: - Model Download

    /// Download a model from HuggingFace Hub without loading it into memory.
    /// Uses the SwiftMaestro-managed Python helper with `huggingface_hub` + Xet
    /// acceleration; supports resume and reports progress to the UI.
    /// After completion the model's `localIfPresent` path will resolve on next access.
    /// - Parameter repair: When true, force a full file pass even if metadata
    ///   looks complete. Existing files are KEPT — the helper skips complete
    ///   files and resumes partial ones, so a repair only fetches missing bytes.
    func downloadModel(_ model: MaestroModel, repair: Bool = false) async throws {
        NSLog("[DOWNLOAD] downloadModel called: %@ (repair=%d)", model.huggingFaceID, repair)

        // Serialize: wait for any in-flight download to finish before starting
        // a new one. Two concurrent Python downloads corrupt each other via the
        // shared HuggingFace cache and venv. The mutex protects the
        // read-modify-write of `downloadChain` from concurrent callers.
        // Same-repo dedupe: a duplicate request (double-clicked repair button,
        // re-fired UI action) awaits the in-flight chain — it must NOT queue
        // another full pass behind it.
        let myChain: Task<Void, any Error> = downloadMutex.withLock {
            if queuedDownloadRepos.contains(model.huggingFaceID), let existing = downloadChain {
                NSLog("[DOWNLOAD] %@ already in flight — awaiting existing download (duplicate request ignored)", model.huggingFaceID)
                return existing
            }
            queuedDownloadRepos.insert(model.huggingFaceID)
            let previous = downloadChain
            let chain = Task { [weak self] in
                if let previous { _ = await previous.result }
                guard let self else { return }
                defer {
                    _ = self.downloadMutex.withLock {
                        self.queuedDownloadRepos.remove(model.huggingFaceID)
                    }
                }
                try await self.performDownload(model, repair: repair)
            }
            downloadChain = chain
            return chain
        }
        try await myChain.value
    }

    /// The actual download work, called only after the previous download has
    /// completed (or if there was none). Separated from `downloadModel` so the
    /// serial-chain logic stays clean.
    private func performDownload(_ model: MaestroModel, repair: Bool) async throws {
        let repoName = model.huggingFaceID.components(separatedBy: "/").last ?? model.huggingFaceID
        let destination = URL(fileURLWithPath: ModelCatalog.modelsRoot)
            .appendingPathComponent("swiftmaestro-models/\(repoName)", isDirectory: true)
        NSLog("[DOWNLOAD] destination: %@", destination.path)

        // Repair NO LONGER wipes the directory. The helper skips complete
        // files (size match) and resumes partials with curl -C -, so wiping
        // only ever destroyed finished shards — production: two queued repairs
        // for the 17.5 GB Qwen3-VL model each deleted the other's completed
        // 5.3 GB shard, trapping the download in a from-scratch loop.
        if repair, FileManager.default.fileExists(atPath: destination.path) {
            NSLog("[DOWNLOAD] repair requested — keeping existing files; helper resumes partials and skips complete files")
        }

        let metadataOnly: Bool
        if repair {
            // Always a FULL pass on repair: the metadata-complete short-circuit
            // below would skip the missing weight shards entirely when only
            // config files are intact.
            metadataOnly = false
        } else if FileManager.default.fileExists(atPath: destination.path) {
            guard !ModelFileHealthService.isMetadataComplete(for: model) else {
                NSLog("[DOWNLOAD] metadata already complete, skipping")
                return
            }
            metadataOnly = true
        } else {
            metadataOnly = false
        }
        NSLog("[DOWNLOAD] metadataOnly=%d", metadataOnly)

        state = .downloading("Downloading \(model.displayName)…")
        NSLog("[DOWNLOAD] state set to downloading")

        // Fetch total weight bytes from HuggingFace's index.json so the
        // observation loop can derive percentage from on-disk bytes.
        let totalExpectedBytes: Int64 = await Self.fetchTotalWeightBytes(
            repoID: model.huggingFaceID
        )
        NSLog("[DOWNLOAD] totalExpectedBytes: %lld", totalExpectedBytes)

        let destinationURL = destination
        let progress = Progress(totalUnitCount: 100)
        downloadProgress = progress
        let observation = Task {
            // Poll on-disk file sizes directly instead of relying on the
            // Python stdout pipe (which is unreliable due to byte-by-byte
            // FileHandle reading and MainActor hopping delays).
            // includeHidden: the helper stages partial files in a hidden
            // .cache subfolder, so without them a long single-shard download
            // looks frozen between file completions.
            let fm = FileManager.default
            var lastReported: Double = 0
            var lastBytes: Int64 = 0
            var lastGrowth = Date()
            while !Task.isCancelled {
                let bytesOnDisk = Self.directorySize(destinationURL, fm: fm, includeHidden: true)
                if bytesOnDisk > lastBytes {
                    lastBytes = bytesOnDisk
                    lastGrowth = Date()
                }
                if totalExpectedBytes > 0 {
                    let fraction = min(Double(bytesOnDisk) / Double(totalExpectedBytes), 1.0)
                    if fraction != lastReported {
                        progress.completedUnitCount = Int64(fraction * 100)
                        modelDownloadProgress[model.id] = fraction
                        lastReported = fraction
                    }
                } else if bytesOnDisk > 0 {
                    // Total unknown — show indeterminate progress with bytes
                    // downloaded. Use a dummy fraction so the bar animates.
                    if lastReported == 0 {
                        modelDownloadProgress[model.id] = nil  // triggers "Downloading..." text
                    }
                }
                // Stall watchdog: hf_transfer/xet chunk stalls can hang a
                // download indefinitely without erroring, and because downloads
                // are SERIALIZED through downloadChain, one hung helper froze
                // every later model at "Queued…" forever. No byte growth for
                // two minutes = cancel so the chain advances and the user can
                // retry instead of staring at a dead spinner.
                if Date().timeIntervalSince(lastGrowth) > 120,
                   totalExpectedBytes == 0 || bytesOnDisk < totalExpectedBytes {
                    NSLog("[DOWNLOAD] stall detected for %@ (no byte growth for 120s) — cancelling so queued downloads can proceed", model.huggingFaceID)
                    HuggingFaceDownloadService.shared.cancelDownload(
                        toDestination: destinationURL.path, reason: "no progress for 120s")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer {
            observation.cancel()
            downloadProgress = nil
            modelDownloadProgress.removeValue(forKey: model.id)
        }

        let token = SecretsStore.resolveValue(name: "HUGGINGFACE_TOKEN", currentProject: "SwiftMaestro")

        let allowPatterns: [String]
        if metadataOnly {
            allowPatterns = ModelFileHealthService.requirements(for: model)
                .filter { !$0.isWeight }
                .map { $0.filename }
        } else {
            allowPatterns = [
                "*.json", "*.safetensors", "*.tinfo", "*.ngl",
                "*.txt", "*.py", "*.model", "*.jinja", "*.md",
                ".gitattributes"
            ]
        }

        _ = try await HuggingFaceDownloadService.shared.download(
            repoID: model.huggingFaceID,
            localDir: destination.path,
            allowPatterns: allowPatterns,
            ignorePatterns: ["*.msgpack", "*.h5", "*.ot"],
            token: token
        )
        state = .idle
    }

    /// Sum of file sizes in a directory (non-recursive). Used by the download
    /// observation loop to derive progress from on-disk bytes instead of
    /// relying on the Python stdout pipe.
    /// `includeHidden`: the download helper stages partial files in a hidden
    /// `.cache` subfolder — progress/stall detection must see those, or a
    /// long single-shard download looks frozen between file completions.
    private nonisolated static func directorySize(_ url: URL, fm: FileManager, includeHidden: Bool = false) -> Int64 {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileType = attrs[.type] as? FileAttributeType else { return 0 }
        if fileType == .typeRegular {
            return (attrs[.size] as? Int64) ?? 0
        }
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : .skipsHiddenFiles
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: options) else { return 0 }
        var total: Int64 = 0
        for item in items {
            if let resourceValues = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                if resourceValues.isDirectory == true {
                    total += directorySize(item, fm: fm, includeHidden: includeHidden)
                } else {
                    total += Int64(resourceValues.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Fetch total weight bytes from a HuggingFace repo's index.json.
    /// The `metadata.total_size` field gives the combined size of all
    /// safetensors weight files — exactly what we need for progress.
    private nonisolated static func fetchTotalWeightBytes(repoID: String) async -> Int64 {
        // Prefer the repo's actual file listing: some repos ship a stale
        // model.safetensors.index.json carried over from a different variant
        // (production: Qwen3-VL-8B-Instruct-4bit's index names four 4-bit
        // shards that no longer exist; the real weights are two differently
        // named shards totalling ~5.8 GB). The API's per-file sizes are
        // authoritative.
        if let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true") {
            do {
                let (data, _) = try await URLSession.shared.data(from: apiURL)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let siblings = json["siblings"] as? [[String: Any]] {
                    let total = siblings.reduce(Int64(0)) { sum, file in
                        guard let name = file["rfilename"] as? String,
                              name.hasSuffix(".safetensors") else { return sum }
                        let size = (file["size"] as? NSNumber)?.int64Value ?? 0
                        return sum + size
                    }
                    if total > 0 { return total }
                }
            } catch {
                // Fall through to the index-based estimate.
            }
        }
        let urlString = "https://huggingface.co/\(repoID)/resolve/main/model.safetensors.index.json"
        guard let url = URL(string: urlString) else { return 0 }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metadata = json["metadata"] as? [String: Any],
                  let totalSize = metadata["total_size"] as? Int64 else { return 0 }
            return totalSize
        } catch {
            return 0
        }
    }

    // MARK: - Model Loading

    /// Load a model from a ``MaestroModel`` descriptor.
    /// Returns the cached container if already loaded.
    func loadModel(_ model: MaestroModel) async throws -> ModelContainer {
        if let cached = modelCache[model.id] {
            touchResident(model.id)
            state = .ready(model.displayName)
            scheduleMechanicPreload(triggeredBy: model)
            return cached
        }

        // Ensure metadata files are present before attempting to load. This is
        // especially important for VLMs, where a missing processor config or
        // chat template can cause cryptic loader errors.
        if model.hasLocalWeights {
            await ModelFileHealthService.repairMetadataIfNeeded(for: model)
            // Install a tools-enabled chat template overlay for models whose
            // stock template lacks a tools block (e.g. DeepSeek-Coder-V2-Lite).
            ModelFileHealthService.repairChatTemplateIfNeeded(for: model)
        }

        // Verify every weight shard is actually present BEFORE attempting to
        // load. An interrupted/partial download can leave some shards missing
        // while others are present; mlx-swift-lm's Module.update(modules:)
        // hits an internal `try!` on a partial weight set and crashes the
        // whole app with UpdateError.mismatchedContainers rather than
        // throwing something catchable. Failing here instead turns that into
        // a normal, recoverable error the UI can show.
        let missingShards = ModelFileHealthService.missingWeightShards(for: model)
        guard missingShards.isEmpty else {
            state = .error("\(model.displayName): incomplete download (missing \(missingShards.count) weight shard(s))")
            throw EngineError.incompleteWeights(model: model.displayName, missingShards: missingShards)
        }

        // Budget-aware residency: evict the least-recently-used model(s) only if
        // loading this one would push the resident set past the memory budget
        // (80% of system RAM by default). Models that fit stay resident together, so
        // switching between them is instant and they can serve agents concurrently.
        let newBytes = Self.bytes(gb: model.estimatedMemoryGB)
        var evictedBytes = evictResidentToFit(additionalBytes: newBytes, excluding: model.id)

        // System-wide available-memory guard. The residency budget above is a
        // static fraction of physical RAM — it cannot see memory held by OTHER
        // logged-in user sessions under fast user switching (their wired GPU
        // heaps are invisible to per-app accounting), which is exactly how the
        // 0.3.6 demo run loaded Gemma 4 + Qwen3-Coder-Next on top of the main
        // session's models and took the machine down (2026-08-20). Fail fast
        // with an actionable message instead of sliding into swap-death.
        let systemAvailable = Self.systemAvailableMemoryBytes()
        if systemAvailable >= 0 {
            // Weights + ~25% for KV cache, activations, and Metal working
            // buffers. Evicted models' pages count as reclaimable even though
            // the kernel may not report them as free yet.
            let required = newBytes + newBytes / 4
            let reserve = max(
                Self.bytes(gb: 6),
                Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.06))
            var effectiveAvailable = systemAvailable + evictedBytes
            if required > effectiveAvailable - reserve {
                // TRY HARDER before refusing: the budget pass above only evicts
                // when the RESIDENT SET exceeds 80% of RAM — it can't see memory
                // held outside this process (other apps, another logged-in
                // session). If SwiftMaestro itself is holding other resident
                // models, dropping them is the fastest way to make room.
                // Skipped while a generation is in flight — evicting the model
                // another agent is streaming from would corrupt that stream;
                // the refusal stands in that case.
                if state != .generating {
                    let extra = evictAllResident(excluding: model.id)
                    if extra > 0 {
                        evictedBytes += extra
                        effectiveAvailable = Self.systemAvailableMemoryBytes() + evictedBytes
                    }
                }
            }
            if required > effectiveAvailable - reserve {
                let needGB = required / 1_073_741_824
                let haveGB = max(0, effectiveAvailable - reserve) / 1_073_741_824
                NSLog("[ENGINE] refusing to load \(model.displayName): need ~\(needGB)GB, available ~\(haveGB)GB (system-wide; evicted \(evictedBytes / 1_073_741_824)GB this call)")
                state = .error("\(model.displayName): not enough memory")
                throw EngineError.insufficientMemory(
                    model: model.displayName, neededGB: needGB, availableGB: haveGB)
            }
        }

        state = .loading(model.displayName)

        // Perform the heavy container load off the main actor so the UI and
        // Accessibility tree stay responsive during the multi-GB weight load.
        let container = try await loadContainer(for: model)

        modelCache[model.id] = container
        lruClock &+= 1
        resident[model.id] = ResidentModel(
            displayName: model.displayName, estimatedBytes: newBytes, lastUsed: lruClock)
        state = .ready(model.displayName)
        downloadProgress = nil
        scheduleMechanicPreload(triggeredBy: model)
        return container
    }

    // MARK: - Mechanic preload

    /// Whether the Mechanic preload has already been scheduled this session.
    private var mechanicPreloadScheduled = false

    /// Preload the Mechanic's small (~3 GB) support model in the background once
    /// the user's main model is ready, so a Maestro → Mechanic delegation skips
    /// the model-load hop on its first use. Pure latency optimization:
    ///
    /// - local-only (never triggers a download in the background)
    /// - runs at utility priority after a short settle delay, and defers while
    ///   a generation is in flight so it never contends with user-facing work
    /// - loadModel's own residency/system-memory guards apply; any failure
    ///   (e.g. insufficient memory on a smaller machine) is logged and
    ///   swallowed — the delegation path still loads on demand
    private func scheduleMechanicPreload(triggeredBy model: MaestroModel) {
        guard !mechanicPreloadScheduled else { return }
        guard model.id != ModelCatalog.mechanicModelID else { return }
        guard ModelCatalog.mechanicModelAvailable,
              let mechanic = ModelCatalog.builtInModels.first(where: {
                  $0.id == ModelCatalog.mechanicModelID
              })
        else { return }
        guard modelCache[mechanic.id] == nil else { return }  // already resident
        mechanicPreloadScheduled = true

        Task.detached(priority: .utility) { [weak self] in
            // Let the UI settle and any immediate user message start first.
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            // Defer while the engine is busy generating (up to ~60s), rather
            // than competing for GPU/disk bandwidth mid-stream.
            for attempt in 0..<10 {
                let busy = await MainActor.run { self.state == .generating }
                if !busy { break }
                if attempt == 9 {
                    NSLog("[ENGINE] Mechanic preload skipped — engine stayed busy")
                    return
                }
                try? await Task.sleep(for: .seconds(6))
            }
            do {
                NSLog("[ENGINE] preloading Mechanic model in background")
                _ = try await self.loadModel(mechanic)
                NSLog("[ENGINE] Mechanic model preloaded and resident")
            } catch {
                NSLog("[ENGINE] Mechanic preload skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Heavy container creation performed off the main actor.
    /// Local loaders/downloader instances are created here so the method is fully
    /// non-isolated and can run on the cooperative pool while the UI stays live.
    nonisolated private func loadContainer(for model: MaestroModel) async throws -> ModelContainer {
        if let localPath = model.localPath {
            let url = URL(fileURLWithPath: localPath)
            if model.isVision {
                let configuration = ModelConfiguration(
                    directory: url, extraEOSTokens: model.extraEOSTokens,
                    toolCallFormat: model.toolCallFormat)
                return try await VLMModelFactory.shared.loadContainer(
                    from: LocalDirectoryDownloader(directory: url),
                    using: MaestroTokenizerLoader(),
                    configuration: configuration
                )
            } else {
                let configuration = ModelConfiguration(
                    directory: url, extraEOSTokens: model.extraEOSTokens,
                    toolCallFormat: model.toolCallFormat)
                return try await LLMModelFactory.shared.loadContainer(
                    from: LocalDirectoryDownloader(directory: url),
                    using: MaestroTokenizerLoader(),
                    configuration: configuration
                )
            }
        } else {
            let configuration = ModelConfiguration(
                id: model.huggingFaceID, extraEOSTokens: model.extraEOSTokens,
                toolCallFormat: model.toolCallFormat)
            let factory: any ModelFactory = model.isVision
                ? VLMModelFactory.shared
                : LLMModelFactory.shared
            return try await factory.loadContainer(
                from: HFHubDownloader(),
                using: MaestroTokenizerLoader(),
                configuration: configuration
            ) { _ in }
        }
    }

    // MARK: - Residency (budget-aware multi-model)

    // MARK: - MLX cache management

    /// Clear BOTH the GPU buffer cache AND the compiled graph cache.
    ///
    /// `MLX.Memory.clearCache()` only frees recycled GPU buffer allocations.
    /// The process-global compiled-function singletons (`compiledSiluProduct`,
    /// `weightedExpertSum` in SwitchLayers.swift, and similar in activation
    /// modules) hold stale references to those freed buffers after a clear.
    /// On the next generation the stale graph errors internally, mlx-swift's
    /// compile wrapper returns a scalar `MLXArray(0)`, and a downstream
    /// `[.ellipsis, ..<k]` index computes an invalid range -> Swift trap.
    ///
    /// Calling `mlx_detail_compile_clear_cache()` (C API, no Swift wrapper in
    /// mlx-swift) purges the compiled graph cache so the singletons re-trace
    /// and re-compile with fresh tensors on next use. The one-time
    /// recompilation cost is negligible vs the 3× decode speedup from keeping
    /// kernel fusion enabled.
    private func clearMLXCaches() {
        MLX.Memory.clearCache()
        _ = mlxDetailCompileClearCache()
    }

    /// C declaration for the MLX compile-cache clear function (mlx/c/compile.h).
    /// The symbol is linked through the MLX → Cmlx dependency chain.
    @_silgen_name("mlx_detail_compile_clear_cache")
    private func mlxDetailCompileClearCache() -> Int32

    /// Bytes for a GB value.
    private static func bytes(gb: Int) -> Int { gb * 1_073_741_824 }

    /// System-wide available memory in bytes (free + inactive + purgeable +
    /// speculative pages), via the shared `SystemMemory` snapshot.
    ///
    /// Unlike `ProcessInfo.physicalMemory` — which the residency budget uses
    /// and which assumes the whole machine belongs to this app — this sees
    /// memory other processes are actually holding, INCLUDING another
    /// logged-in user session's wired GPU heaps under fast user switching.
    /// That blind spot is what let 0.3.6 load Gemma 4 + Qwen3-Coder-Next on
    /// top of the main session's resident models on the demo machine and take
    /// the system down (2026-08-20).
    ///
    /// Returns -1 if the kernel call fails (callers must fail-open — never
    /// block a load because a statistic was unavailable).
    nonisolated static func systemAvailableMemoryBytes() -> Int {
        SystemMemory.availableMemoryBytes()
    }

    /// Resident memory budget: total system RAM minus a safety reserve for the OS
    /// and other apps (default 20%, configurable via
    /// `models.systemMemoryReserveFraction`). Caps the sum of resident model
    /// weights so the set stays within what can be wired without paging.
    /// On 64GB machines the old 10% reserve caused beach balls at ~47GB because
    /// KV cache + GPU buffers + activations push actual usage well above the
    /// model's estimated weight size.
    var residentBudgetBytes: Int {
        let raw = UserDefaults.standard.object(forKey: "models.systemMemoryReserveFraction") as? Double
        let reserve = min(max(raw ?? 0.20, 0.0), 0.5)
        return Int(Double(ProcessInfo.processInfo.physicalMemory) * (1.0 - reserve))
    }

    /// Sum of estimated weight bytes across resident models.
    var residentUsedBytes: Int { resident.values.reduce(0) { $0 + $1.estimatedBytes } }

    /// Mark a resident model as most-recently-used.
    private func touchResident(_ id: String) {
        guard resident[id] != nil else { return }
        lruClock &+= 1
        resident[id]?.lastUsed = lruClock
    }

    /// Evict least-recently-used resident models until `additionalBytes` fits
    /// within `residentBudgetBytes` (never evicting `excluding`). Clears the MLX
    /// buffer cache once if anything was evicted.
    ///
    /// Returns the estimated bytes evicted this call, so the system-memory
    /// guard can count them as reclaimable even though the pages may not show
    /// as free yet (GPU resources drain asynchronously).
    @discardableResult
    private func evictResidentToFit(additionalBytes: Int, excluding: String) -> Int {
        let budget = residentBudgetBytes
        var evictedBytes = 0
        while residentUsedBytes + additionalBytes > budget {
            let candidate = resident
                .filter { $0.key != excluding }
                .min { $0.value.lastUsed < $1.value.lastUsed }
            guard let (id, info) = candidate else { break }
            modelCache.removeValue(forKey: id)
            promptCaches = promptCaches.filter { !$0.key.hasSuffix("::" + id) }
            resident.removeValue(forKey: id)
            evictedBytes += info.estimatedBytes
            NSLog("[ENGINE] evicted LRU model \(id) (~\(info.estimatedBytes / 1_073_741_824)GB) to fit \(excluding); budget \(budget / 1_073_741_824)GB")
        }
        if evictedBytes > 0 { clearMLXCaches() }
        return evictedBytes
    }

    /// Evict EVERY resident model except `excluding` — the last resort before
    /// refusing a load on system-wide memory grounds. The budget-based pass
    /// (evictResidentToFit) only fires when the resident set exceeds the 80%
    /// RAM budget, so memory pressure from OUTSIDE this process (other apps,
    /// another logged-in session's wired GPU heaps) needs this harder pass.
    /// Callers must hold off while a generation is in flight (evicting the
    /// streaming model would corrupt the stream).
    @discardableResult
    private func evictAllResident(excluding: String) -> Int {
        var evictedBytes = 0
        for (id, info) in resident where id != excluding {
            modelCache.removeValue(forKey: id)
            promptCaches = promptCaches.filter { !$0.key.hasSuffix("::" + id) }
            resident.removeValue(forKey: id)
            evictedBytes += info.estimatedBytes
            NSLog("[ENGINE] evicted resident model \(id) (~\(info.estimatedBytes / 1_073_741_824)GB) to fit \(excluding) under system-wide memory pressure")
        }
        if evictedBytes > 0 { clearMLXCaches() }
        return evictedBytes
    }

    /// Snapshot of resident models for the Settings readout, most-recently-used first.
    var residentModelsReadout: [ResidentModelReadout] {
        resident
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .map {
                ResidentModelReadout(
                    id: $0.key, name: $0.value.displayName,
                    gb: $0.value.estimatedBytes / 1_073_741_824)
            }
    }

    // MARK: - Generation

    /// Stream tokens from the model for a given chat history.
    func generate(
        messages: [Message],
        model: MaestroModel,
        temperature: Float? = nil,
        maxTokens: Int = 4096
    ) async throws -> AsyncStream<GenerationOutput> {
        cancel()
        state = .generating
        ModelActivitySampler.shared.register(model, state: .loading)

        let container = try await loadModel(model)
        ModelActivitySampler.shared.register(model, state: .idle)

        // Map SwiftMaestro messages to MLX Chat.Message
        let chat: [Chat.Message] = messages.map { msg in
            let role: Chat.Message.Role = switch msg.role {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            }
            return Chat.Message(role: role, content: msg.content)
        }

        // Thinking mode + sampling come from SwiftMaestro's own settings
        // (self-hosted — independent of any server-side config).
        // Thinking defaults OFF for a clean, fast chat experience; reasoning can
        // be re-enabled via the `tuning.enableThinking` setting. `enable_thinking`
        // is passed to the model's chat template via additionalContext.
        let defaults = UserDefaults.standard
        let thinkingEnabled = (defaults.object(forKey: "tuning.enableThinking") as? Bool) ?? false
        // Precedence: explicit arg > user's global Tuning override (only if set) >
        // per-model recommended > hard default. Keeps each model on its own
        // sampling instead of one global temperature.
        let resolvedTemp = temperature
            ?? (defaults.object(forKey: "tuning.temperature") as? Double).map { Float($0) }
            ?? model.recTemperature.map { Float($0) }
            ?? 1.0
        let resolvedTopP = (defaults.object(forKey: "tuning.topP") as? Double).map { Float($0) }
            ?? model.recTopP.map { Float($0) }
            ?? 0.95
        let resolvedRepPenalty = (defaults.object(forKey: "tuning.repetitionPenalty") as? Double).map { Float($0) }
            ?? model.recRepetitionPenalty.map { Float($0) }
            ?? 1.05
        let parameters = GenerateParameters(
            maxKVSize: model.maxKVSize,
            temperature: resolvedTemp,
            topP: resolvedTopP,
            repetitionPenalty: resolvedRepPenalty,
            // Process the (large) system+tools prefix in bigger chunks than the
            // 512 default to speed first-turn / cache-miss prefill. Per-agent
            // prefix KV reuse still trims this to the changed suffix on warm turns.
            prefillStepSize: 1024
        )

        // Verify-per-model: only advertise tools to models whose tool round-trip
        // has been confirmed. Unverified models (e.g. Qwen3-Coder, pending its
        // tool-call format support) run as plain chat — no broken tool path.
        //
        // Tool sources are merged here: native (in-process) tools plus any tools
        // discovered from user-enabled MCP servers. The loop below is
        // source-agnostic and routes each call to whichever source owns it.
        let mcp = mcpService
        let toolSchemas: [ToolSpec]?
        if model.advertisesTools {
            var specs = MaestroTools.schemas
            if let mcp { specs += await mcp.currentSchemas() }
            // JSON round-trip to normalize all nested values to proper JSON
            // types before swift-jinja's Value(any:) processes them.
            toolSchemas = specs.isEmpty ? nil : (specs.map { spec in
                guard let data = try? JSONSerialization.data(withJSONObject: spec as Any),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: any Sendable]
                else { return spec }
                return obj
            })
        } else {
            toolSchemas = nil
        }

        return AsyncStream<GenerationOutput> { continuation in
            self.generateTask = Task {
                // Agentic loop: generate -> if the model calls tools, execute them,
                // feed results back as tool messages, and re-generate until the
                // model produces a final answer. No iteration budget (local
                // inference has no token cost); termination is the model finishing
                // or the user cancelling. The loop is tool-source-agnostic: calls
                // route to native tools or MCP.
                var conversation = chat
                do {
                    iterations: while !Task.isCancelled {
                        ProcessResourceSampler.shared.startGeneration()
                        ModelActivitySampler.shared.startGeneration(id: model.id)
                        let input = UserInput(
                            chat: conversation,
                            tools: toolSchemas,
                            additionalContext: ["enable_thinking": thinkingEnabled]
                        )
                        nonisolated(unsafe) let capturedInput = input
                        nonisolated(unsafe) let pc = self.legacyPromptCache
                        let modelID = model.id
                        var pendingCalls: [ToolCall] = []
                        let stream = try await container.perform { context in
                            let lmInput = try await context.processor.prepare(input: capturedInput)
                            let fullTokens = lmInput.text.tokens.asArray(Int.self)

                            // Reuse the persistent prompt cache when it belongs to
                            // the same model and is trimmable. Common-prefix match
                            // against the previously-fed tokens, trim the cache to
                            // that prefix, and prefill only the changed suffix.
                            let hasUsableCache = pc.isReady
                                && pc.modelID == modelID
                                && !pc.caches.isEmpty
                            var prefix = 0
                            var canReuse = false
                            if hasUsableCache {
                                let minOffset = pc.caches.map { $0.offset }.min() ?? 0
                                let base = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                                // Pure append: the whole previous prompt is a prefix of the
                                // new chat, so the tokens generated last round (cache offset
                                // − stored prompt) are the assistant turn that immediately
                                // follows — reusable with NO trim. This is the only way
                                // non-trimmable MoE caches can ever be reused across rounds.
                                let pureAppend = !pc.tokens.isEmpty
                                    && base == pc.tokens.count
                                    && minOffset >= pc.tokens.count
                                // Clamp: keep ≥1 token to prefill, never exceed what
                                // the cache actually holds (e.g. after a cancel).
                                prefix = pureAppend
                                    ? min(minOffset, fullTokens.count - 1)
                                    : min(base, minOffset, fullTokens.count - 1)
                                if prefix < 0 { prefix = 0 }
                                // A cache trim is only needed when the conversation diverged.
                                // For a pure append — the normal agent round — nothing is
                                // trimmed, so non-trimmable MoE caches must NOT block reuse.
                                canReuse = !(prefix < minOffset) || pc.caches.allSatisfy { $0.isTrimmable }
                            }

                            let inputForGen: LMInput
                            let cacheForGen: [KVCache]
                            if canReuse && prefix > 0 {
                                for c in pc.caches { let amount = c.offset - prefix; if amount > 0 { c.trim(amount) } }
                                let deltaInts = Array(fullTokens[prefix...]).map { Int32($0) }
                                // Keep delta tokens 1-D. mlx-swift-lm's LLMModel.prepare and TokenIterator
                                // internally add the batch axis via .newAxis; passing a 2-D array here
                                // makes chunking slice the wrong axis and feeds the model 3-D/1-D inputs
                                // instead of 2-D [batch, sequence], crashing in convertToToken's subscript.
                                let deltaArray = MLXArray(deltaInts)
                                inputForGen = LMInput(text: .init(tokens: deltaArray))
                                cacheForGen = pc.caches
                                NSLog("[PERF] cache reuse: prefix=\(prefix)/\(fullTokens.count), delta=\(deltaInts.count) tok")
                            } else {
                                let fresh = context.model.newCache(parameters: parameters)
                                pc.caches = fresh
                                inputForGen = lmInput
                                cacheForGen = fresh
                                NSLog("[PERF] cache fresh: prefill=\(fullTokens.count) tok")
                            }
                            pc.tokens = fullTokens
                            pc.modelID = modelID
                            pc.isReady = true

                            return try MLXLMCommon.generate(
                                input: inputForGen,
                                cache: cacheForGen,
                                parameters: parameters,
                                context: context,
                                tools: toolSchemas?.map { $0 as [String: any Sendable] }
                            )
                        }
                        var roundContent = ""
                        streamLoop: for await generation in stream {
                            guard !Task.isCancelled else { break iterations }
                            switch generation {
                            case .chunk(let chunk):
                                ProcessResourceSampler.shared.recordToken()
                                ModelActivitySampler.shared.recordToken(id: model.id)
                                roundContent += chunk
                                if Self.degenerateTrimmed(roundContent) != nil {
                                    NSLog("[ENGINE] degeneration guard: repetition loop detected — stopping the round")
                                    break streamLoop
                                }
                                continuation.yield(.token(chunk))
                            case .info(let info):
                                NSLog("[PERF] prompt=\(info.promptTokenCount) tok in \(String(format: "%.2f", info.promptTime))s (\(String(format: "%.0f", info.promptTokensPerSecond)) tok/s prefill); gen=\(info.generationTokenCount) tok in \(String(format: "%.2f", info.generateTime))s (\(String(format: "%.1f", info.tokensPerSecond)) tok/s)")
                                await MainActor.run {
                                    self.tokensPerSecond = info.tokensPerSecond
                                }
                                AIBroadcastService.recordToken(
                                    totalTokens: info.generationTokenCount,
                                    tokensPerSecond: info.tokensPerSecond
                                )
                                continuation.yield(.info(tokensPerSecond: info.tokensPerSecond))
                            case .toolCall(let call):
                                pendingCalls.append(call)
                            }
                        }
                        ProcessResourceSampler.shared.stopGeneration()
                        ModelActivitySampler.shared.stopGeneration(id: model.id)
                        // No tool calls -> the model produced its final answer.
                        if pendingCalls.isEmpty { break iterations }
                        // Execute each tool call and feed the result back for the next round.
                        // Native tools take precedence; otherwise route to MCP.
                        for call in pendingCalls {
                            let name = call.function.name
                            continuation.yield(.toolCall(name: name))
                            let result: String
                            if await MaestroTools.handles(name) {
                                result = await MaestroTools.execute(call)
                            } else if let mcp, await mcp.handles(name) {
                                result = await mcp.execute(call)
                            } else {
                                result = await MaestroTools.execute(call)
                            }
                            conversation.append(.tool(result))
                        }
                    }
                } catch {
                    // Propagate via the stream — caller handles errors / fallback
                }
                ProcessResourceSampler.shared.stopGeneration()
                ProcessResourceSampler.shared.stopGeneration()
                ModelActivitySampler.shared.stopGeneration(id: model.id)
                continuation.finish()
                await MainActor.run {
                    self.state = .ready(model.displayName)
                }
            }
        }
    }

    // MARK: - Tool schema sanitization

    /// Sanitize tool schemas through a JSON round-trip so all values are proper
    /// JSON types (String/Number/Boolean/Array/Dict/NSNull) before they hit
    /// swift-jinja's `Value(any:)`, which can mis-bridge `[String: any Sendable]`
    /// existential containers. Kept as a non-isolated helper so callers can run
    /// it off the main actor before entering a `@MainActor` generation method.
    nonisolated static func sanitizeToolSchemas(_ toolSchemas: [ToolSpec]?) -> [ToolSpec]? {
        guard let toolSchemas else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: toolSchemas as Any)
            let obj = try JSONSerialization.jsonObject(with: data)
            let normalized = normalizeSchemaTypes(obj)
            return normalized as? [ToolSpec] ?? toolSchemas
        } catch {
            NSLog("[ENGINE] tool schema JSON round-trip failed: \(error), using raw")
            return toolSchemas
        }
    }

    /// Recursively normalize JSON Schema `type` values to plain strings.
    ///
    /// Gemma 4's chat template applies `value['type'] | upper` in Jinja, which
    /// crashes when `type` is an array (e.g. `["string", "null"]` emitted by some
    /// MCP servers) or any non-string value. This helper collapses multi-type
    /// arrays to the first non-null string and forces unknown/missing types to
    /// "string" so the chat template can render the tool surface.
    nonisolated private static func normalizeSchemaTypes(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            if let typeValue = dict["type"] {
                dict["type"] = normalizedTypeString(typeValue)
            }
            // Recurse into every nested dictionary or array so we catch `type`
            // fields inside `function.parameters.properties`, `items`, `anyOf`,
            // `response`, and any other nested schema the chat template touches.
            for (key, child) in dict {
                if child is [String: Any] || child is [Any] {
                    dict[key] = normalizeSchemaTypes(child)
                }
            }
            return dict as [String: Any]
        }
        if let arr = value as? [Any] {
            return arr.map { normalizeSchemaTypes($0) }
        }
        return value
    }

    /// Collapse a JSON Schema `type` value to a single string safe for Gemma 4.
    nonisolated private static func normalizedTypeString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [Any] {
            for item in arr {
                if let s = item as? String, s.lowercased() != "null" {
                    return s
                }
            }
        }
        return "string"
    }

    // MARK: - Single round (for the pluggable in-process backend)

    /// Run ONE generation pass over a prepared chat (no tool loop). Streams
    /// content tokens via `onToken` and decode-rate via `onInfo`, and returns the
    /// full content plus any tool calls the model requested (parsed by
    /// mlx-swift-lm's model-specific tool parser). The agentic loop (tool
    /// execution, project/cwd injection, delegation) lives in AgentExecutor; this
    /// is just the backend's generation primitive. Reuses the persistent prompt
    /// KV cache for cross-round prefix reuse.
    @MainActor
    func generateRound(
        chatTurns: [ChatTurn],
        toolSchemas: [ToolSpec]?,
        model: MaestroModel,
        sessionKey: String,
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        maxTokens: Int = 32768,
        onToken: @escaping @Sendable (String) -> Void,
        onInfo: @escaping @Sendable (Double) -> Void
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
        state = .generating
        ModelActivitySampler.shared.register(model, state: .loading)
        let chat: [Chat.Message] = chatTurns.map { turn in
            let images: [UserInput.Image] = turn.images.compactMap { data in
                guard let ciImage = CIImage(data: data) else { return nil }
                return .ciImage(ciImage)
            }
            switch turn.role {
            case "system": return .system(turn.content)
            case "assistant": return .assistant(turn.content)
            case "tool": return .tool(turn.content)
            default: return .user(turn.content, images: images)
            }
        }
        let container = try await loadModel(model)
        ModelActivitySampler.shared.register(model, state: .idle)

        // SELF-HEALING: Check memory pressure before generation.
        // If system memory is critically low, trigger compaction to free KV cache
        // before it can overflow Metal's ~80GB single-buffer limit.
        let availableBytes = Self.systemAvailableMemoryBytes()
        let modelBytes = UInt64(model.estimatedMemoryGB) * 1_073_741_824
        let kvReserveBytes: UInt64 = 8_589_934_592  // 8 GB reserve for KV cache growth
        if availableBytes < modelBytes + kvReserveBytes {
            let availableGB = Double(availableBytes) / 1_073_741_824
            let neededGB = Double(modelBytes + kvReserveBytes) / 1_073_741_824
            NSLog("[ENGINE] MEMORY PRESSURE: available=%.1fGB < needed=%.1fGB — triggering compaction before generation", availableGB, neededGB)
            // Signal the chat view model to compact. This is a best-effort attempt;
            // if it fails, we proceed anyway (the KV cache RotatingKVCache will
            // handle overflow via eviction).
            NotificationCenter.default.post(
                name: .memoryPressureCompactionNeeded,
                object: nil,
                userInfo: ["modelID": model.id, "availableBytes": availableBytes]
            )
            // Brief pause to let compaction start (non-blocking — it runs async).
            try? await Task.sleep(for: .milliseconds(200))
        }

        // mlx-swift-lm #258 (Gemma 4 broadcast crash with repPen) is fixed in the
        // vendored RepetitionContext (rank-normalized gather), so the penalty
        // applies uniformly across model families.
        let repPen: Float? = Float(model.tunedRepetitionPenalty)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: model.maxKVSize,
            temperature: Float(temperature), topP: Float(topP), repetitionPenalty: repPen,
            // 256-token window: the library default of 20 barely covers a phrase,
            // so section-level repetition slipped past the penalty entirely.
            repetitionContextSize: 256, prefillStepSize: 1024)

        let input = UserInput(
            chat: chat, tools: toolSchemas,
            additionalContext: ["enable_thinking": thinkingEnabled])
        nonisolated(unsafe) let capturedInput = input
        nonisolated(unsafe) let pc = cache(forSession: sessionKey + "::" + model.id)
        if let last = lastGenerationModelID, last != model.id {
            // The prompt cache is keyed by session + model id, so a model switch
            // never collides with the previous model's state — and resetting here
            // would destroy the RETURNING model's intact cache, forcing a full
            // re-prefill of the whole conversation on every delegation round-trip
            // (Maestro 30K tok → Mechanic 25K tok → Maestro 30K tok… ≈ 2.5 min of
            // prefill per ask_mechanic). Prefix matching below safely reuses what
            // it can (pure append → no trim) and falls back to a fresh prefill on
            // divergence, so keep the cache and let it do its job.
            NSLog("[ENGINE] model switch \(last) -> \(model.id): keeping prompt cache (prefix reuse if append-only)")
        }
        lastGenerationModelID = model.id
        let modelID = model.id
        // Per-run random state, scoped to this generation's task so concurrent
        // agents don't race on MLX's global PRNG (an unevaluated MLXArray).
        let rngState = MLXRandom.RandomState(
            seed: DispatchTime.now().uptimeNanoseconds
                &+ UInt64(bitPattern: Int64(truncatingIfNeeded: sessionKey.hashValue)))

        // Wire the resident set during generation so the active model (incl. a
        // ~65GB 122B) stays resident/non-paged regardless of load order. Sized to
        // the current resident total and capped at the budget. The custom policy
        // does not gate admission, so concurrent agent generations aren't
        // serialized; the cap still bounds total wiring.
        let wiredTicket = WiredMemoryTicket(
            size: residentUsedBytes,
            policy: ResidencyWiredPolicy(capBytes: residentBudgetBytes),
            kind: .active)

        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: capturedInput)
            let fullTokens = lmInput.text.tokens.asArray(Int.self)
            let hasUsableCache = pc.isReady
                && pc.modelID == modelID
                && !pc.caches.isEmpty
            var prefix = 0
            var canReuse = false
            if hasUsableCache {
                let minOffset = pc.caches.map { $0.offset }.min() ?? 0
                let base = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                // Pure append: the whole previous prompt is a prefix of the new chat, so
                // the tokens generated last round (cache offset − stored prompt) are the
                // assistant turn that immediately follows — reusable with NO trim. This is
                // the only way non-trimmable MoE caches can ever be reused across rounds;
                // without it every round re-prefills the entire conversation.
                let pureAppend = !pc.tokens.isEmpty
                    && base == pc.tokens.count
                    && minOffset >= pc.tokens.count
                prefix = pureAppend
                    ? min(minOffset, fullTokens.count - 1)
                    : min(base, minOffset, fullTokens.count - 1)
                if prefix < 0 { prefix = 0 }
                // A cache trim is only required when the conversation diverged (common
                // prefix is shorter than what the cache holds). For a pure append — the
                // normal agent round — nothing is trimmed, so non-trimmable caches (most
                // of a MoE model's layers) must NOT block prefix reuse. Only demand
                // trimmability when a trim is actually needed.
                canReuse = !(prefix < minOffset) || pc.caches.allSatisfy { $0.isTrimmable }
            }
            let inputForGen: LMInput
            let cacheForGen: [KVCache]
            if canReuse && prefix > 0 {
                for c in pc.caches { let amount = c.offset - prefix; if amount > 0 { c.trim(amount) } }
                let deltaInts = Array(fullTokens[prefix...]).map { Int32($0) }
                // Keep delta tokens 1-D. mlx-swift-lm's LLMModel.prepare and TokenIterator
                // internally add the batch axis via .newAxis; passing a 2-D array here
                // makes chunking slice the wrong axis and feeds the model 3-D/1-D inputs
                // instead of 2-D [batch, sequence], crashing in convertToToken's subscript.
                let deltaArray = MLXArray(deltaInts)
                inputForGen = LMInput(text: .init(tokens: deltaArray))
                cacheForGen = pc.caches
                NSLog("[PERF] cache reuse: prefix=\(prefix)/\(fullTokens.count), delta=\(deltaInts.count) tok")
            } else {
                // Diagnose WHY reuse failed so cache regressions are visible in logs:
                // which gate failed (ready/model/empty/trimmable) or how early the
                // token prefix diverged (rawPrefix) vs what the cache held (offset).
                let trimmable = pc.caches.filter { $0.isTrimmable }.count
                let rawPrefix = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                NSLog("[PERF] cache miss: ready=\(pc.isReady) model=\(pc.modelID == modelID) slots=\(pc.caches.count) trimmable=\(trimmable) rawPrefix=\(rawPrefix)")
                let fresh = context.model.newCache(parameters: parameters)
                pc.caches = fresh
                inputForGen = lmInput
                cacheForGen = fresh
                NSLog("[PERF] cache fresh: prefill=\(fullTokens.count) tok")
            }
            pc.tokens = fullTokens
            pc.modelID = modelID
            pc.isReady = true
            // Wrap generation so the loop Task it spawns inherits the per-run
            // random state (task-local), keeping concurrent sampling safe.
            // `withError` additionally scopes an MLX error handler: a runtime
            // MLX error (e.g. an unsupported checkpoint's shape mismatch) is
            // surfaced as a thrown Swift `MLXError` instead of mlx-swift's
            // default handler calling `fatalError` and crashing the whole app.
            // The decode Task mlx-swift spawns inside `generate` inherits this
            // task-local handler, so it can't fatal-error mid-stream either; the
            // thrown error propagates out through `container.perform` and is
            // shown by ChatViewModel as an error message.
            return try withError {
                try withRandomState(rngState) {
                    try MLXLMCommon.generate(
                        input: inputForGen, cache: cacheForGen,
                        parameters: parameters, context: context,
                        wiredMemoryTicket: wiredTicket)
                }
            }
        }

        var content = ""
        var toolCalls: [RoundToolCall] = []
        ProcessResourceSampler.shared.startGeneration()
        ModelActivitySampler.shared.startGeneration(id: model.id)
        streamLoop: for await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let chunk):
                ProcessResourceSampler.shared.recordToken()
                ModelActivitySampler.shared.recordToken(id: model.id)
                content += chunk
                if let trimmed = Self.degenerateTrimmed(content) {
                    NSLog("[ENGINE] degeneration guard: repetition loop detected — truncated and stopped the round")
                    content = trimmed
                    break streamLoop
                }
                onToken(chunk)
            case .info(let info):
                NSLog("[PERF] prompt=\(info.promptTokenCount) tok (\(String(format: "%.0f", info.promptTokensPerSecond)) tok/s prefill); gen=\(info.generationTokenCount) tok (\(String(format: "%.1f", info.tokensPerSecond)) tok/s)")
                self.tokensPerSecond = info.tokensPerSecond
                AIBroadcastService.recordToken(
                    totalTokens: info.generationTokenCount,
                    tokensPerSecond: info.tokensPerSecond
                )
                onInfo(info.tokensPerSecond)
            case .toolCall(let call):
                let argsObj = call.function.arguments.mapValues { $0.anyValue }
                let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(RoundToolCall(
                    id: UUID().uuidString, name: call.function.name, arguments: argsJSON))
            }
        }
        ProcessResourceSampler.shared.stopGeneration()
        ModelActivitySampler.shared.stopGeneration(id: model.id)
        state = .ready(model.displayName)
        return (content, toolCalls)
    }

    /// Generation round that passes raw wire-format messages through the
    /// `.messages()` path in `UserInput`, preserving `tool_calls` and
    /// `tool_call_id` fields so the Gemma 4 Jinja template can match tool
    /// results to their originating calls.
    @MainActor
    func generateRound(
        wireMessages: [[String: any Sendable]],
        images: [UserInput.Image],
        toolSchemas: [ToolSpec]?,
        model: MaestroModel,
        sessionKey: String,
        temperature: Double,
        topP: Double,
        thinkingEnabled: Bool,
        maxTokens: Int = 32768,
        onToken: @escaping @Sendable (String) -> Void,
        onInfo: @escaping @Sendable (Double) -> Void
    ) async throws -> (content: String, toolCalls: [RoundToolCall]) {
        state = .generating
        ModelActivitySampler.shared.register(model, state: .loading)
        let container = try await loadModel(model)
        ModelActivitySampler.shared.register(model, state: .idle)
        // mlx-swift-lm #258 (Gemma 4 broadcast crash with repPen) is fixed in the
        // vendored RepetitionContext (rank-normalized gather), so the penalty
        // applies uniformly across model families.
        let repPen: Float? = Float(model.tunedRepetitionPenalty)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: model.maxKVSize,
            temperature: Float(temperature), topP: Float(topP), repetitionPenalty: repPen,
            // 256-token window: the library default of 20 barely covers a phrase,
            // so section-level repetition slipped past the penalty entirely.
            repetitionContextSize: 256, prefillStepSize: 1024)

        // .messages() path: raw dictionaries pass through DefaultMessageGenerator
        // untouched, preserving tool_calls and tool_call_id for the Jinja template.
        NSLog("[ENGINE] generateRound messages=\(wireMessages.count) images=\(images.count) hf=\(model.huggingFaceID)")
        let input = UserInput(
            messages: wireMessages, images: images, tools: toolSchemas,
            additionalContext: ["enable_thinking": thinkingEnabled])
        nonisolated(unsafe) let capturedInput = input
        nonisolated(unsafe) let pc = cache(forSession: sessionKey + "::" + model.id)
        if let last = lastGenerationModelID, last != model.id {
            // Keep the prompt cache across model switches (see the chatTurns
            // generateRound for the full rationale) — prefix matching reuses an
            // append-only cache and falls back to fresh prefill on divergence.
            // Resetting here cost a full re-prefill of the whole conversation on
            // every delegation round-trip.
            NSLog("[ENGINE] model switch \(last) -> \(model.id): keeping prompt cache (prefix reuse if append-only)")
            // Keep previous models resident; loadModel will evict only if memory
            // budget requires. This lets Maestro (Qwen) and Scribe (Gemma)
            // stay loaded simultaneously instead of thrashing on every switch.
        }
        lastGenerationModelID = model.id
        let modelID = model.id
        let rngState = MLXRandom.RandomState(
            seed: DispatchTime.now().uptimeNanoseconds
                &+ UInt64(bitPattern: Int64(truncatingIfNeeded: sessionKey.hashValue)))

        let wiredTicket = WiredMemoryTicket(
            size: residentUsedBytes,
            policy: ResidencyWiredPolicy(capBytes: residentBudgetBytes),
            kind: .active)

        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: capturedInput)
            let fullTokens = lmInput.text.tokens.asArray(Int.self)
            let hasUsableCache = pc.isReady
                && pc.modelID == modelID
                && !pc.caches.isEmpty
            var prefix = 0
            var canReuse = false
            if hasUsableCache {
                let minOffset = pc.caches.map { $0.offset }.min() ?? 0
                let base = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                // Pure append: the whole previous prompt is a prefix of the new chat, so
                // the tokens generated last round (cache offset − stored prompt) are the
                // assistant turn that immediately follows — reusable with NO trim. This is
                // the only way non-trimmable MoE caches can ever be reused across rounds;
                // without it every round re-prefills the entire conversation.
                let pureAppend = !pc.tokens.isEmpty
                    && base == pc.tokens.count
                    && minOffset >= pc.tokens.count
                prefix = pureAppend
                    ? min(minOffset, fullTokens.count - 1)
                    : min(base, minOffset, fullTokens.count - 1)
                if prefix < 0 { prefix = 0 }
                // A cache trim is only required when the conversation diverged (common
                // prefix is shorter than what the cache holds). For a pure append — the
                // normal agent round — nothing is trimmed, so non-trimmable caches (most
                // of a MoE model's layers) must NOT block prefix reuse. Only demand
                // trimmability when a trim is actually needed.
                canReuse = !(prefix < minOffset) || pc.caches.allSatisfy { $0.isTrimmable }
            }
            let inputForGen: LMInput
            let cacheForGen: [KVCache]
            if canReuse && prefix > 0 {
                for c in pc.caches { let amount = c.offset - prefix; if amount > 0 { c.trim(amount) } }
                let deltaInts = Array(fullTokens[prefix...]).map { Int32($0) }
                // Keep delta tokens 1-D. mlx-swift-lm's LLMModel.prepare and TokenIterator
                // internally add the batch axis via .newAxis; passing a 2-D array here
                // makes chunking slice the wrong axis and feeds the model 3-D/1-D inputs
                // instead of 2-D [batch, sequence], crashing in convertToToken's subscript.
                let deltaArray = MLXArray(deltaInts)
                inputForGen = LMInput(text: .init(tokens: deltaArray))
                cacheForGen = pc.caches
                NSLog("[PERF] cache reuse: prefix=\(prefix)/\(fullTokens.count), delta=\(deltaInts.count) tok")
            } else {
                let trimmable = pc.caches.filter { $0.isTrimmable }.count
                let rawPrefix = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                NSLog("[PERF] cache miss: ready=\(pc.isReady) model=\(pc.modelID == modelID) slots=\(pc.caches.count) trimmable=\(trimmable) rawPrefix=\(rawPrefix)")
                let fresh = context.model.newCache(parameters: parameters)
                pc.caches = fresh
                inputForGen = lmInput
                cacheForGen = fresh
                NSLog("[PERF] cache fresh: prefill=\(fullTokens.count) tok")
            }
            pc.tokens = fullTokens
            pc.modelID = modelID
            pc.isReady = true
            return try withError {
                try withRandomState(rngState) {
                    try MLXLMCommon.generate(
                        input: inputForGen, cache: cacheForGen,
                        parameters: parameters, context: context,
                        wiredMemoryTicket: wiredTicket,
                        tools: toolSchemas?.map { $0 as [String: any Sendable] })
                }
            }
        }

        var content = ""
        var toolCalls: [RoundToolCall] = []
        ProcessResourceSampler.shared.startGeneration()
        ModelActivitySampler.shared.startGeneration(id: model.id)
        streamLoop: for await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let chunk):
                ProcessResourceSampler.shared.recordToken()
                ModelActivitySampler.shared.recordToken(id: model.id)
                content += chunk
                if let trimmed = Self.degenerateTrimmed(content) {
                    NSLog("[ENGINE] degeneration guard: repetition loop detected — truncated and stopped the round")
                    content = trimmed
                    break streamLoop
                }
                onToken(chunk)
            case .info(let info):
                NSLog("[PERF] prompt=\(info.promptTokenCount) tok (\(String(format: "%.0f", info.promptTokensPerSecond)) tok/s prefill); gen=\(info.generationTokenCount) tok (\(String(format: "%.1f", info.tokensPerSecond)) tok/s)")
                self.tokensPerSecond = info.tokensPerSecond
                AIBroadcastService.recordToken(
                    totalTokens: info.generationTokenCount,
                    tokensPerSecond: info.tokensPerSecond
                )
                onInfo(info.tokensPerSecond)
            case .toolCall(let call):
                let argsObj = call.function.arguments.mapValues { $0.anyValue }
                let argsJSON = (try? JSONSerialization.data(withJSONObject: argsObj))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append(RoundToolCall(
                    id: UUID().uuidString, name: call.function.name, arguments: argsJSON))
            }
        }
        ProcessResourceSampler.shared.stopGeneration()
        ModelActivitySampler.shared.stopGeneration(id: model.id)
        state = .ready(model.displayName)
        return (content, toolCalls)
    }

    // MARK: - Degeneration Guard

    /// Index in `tail` where a back-to-back repeating chunk run starts, or nil.
    /// Catches model repetition loops ("<br>"×500, hex-blob echoes) early
    /// enough to stop the round instead of streaming garbage for minutes.
    /// Chunks made of one repeated character ("----", "====") are ignored so
    /// markdown rules and ASCII art never false-trip.
    static func degenerationRunStart(in tail: Substring) -> Substring.Index? {
        let minRepeats = 8
        var chunkLen = 4
        while chunkLen <= 64, tail.count >= chunkLen * minRepeats {
            defer { chunkLen += 1 }
            let chunkStart = tail.index(tail.endIndex, offsetBy: -chunkLen)
            let chunk = tail[chunkStart...]
            if Set(chunk).count == 1 { continue }
            var runStart = chunkStart
            var repeats = 1
            while repeats < minRepeats,
                  let prev = tail.index(runStart, offsetBy: -chunkLen, limitedBy: tail.startIndex) {
                if tail[prev..<runStart] == chunk {
                    runStart = prev
                    repeats += 1
                } else { break }
            }
            if repeats >= minRepeats { return runStart }
        }
        return nil
    }

    /// When the tail of `content` is a repetition loop, returns the content
    /// with the repeated run removed (one occurrence kept). Nil when clean.
    /// Only inspected once content passes 512 chars; the scan window is the
    /// trailing 4096 chars so the per-token cost stays negligible.
    static func degenerateTrimmed(_ content: String) -> String? {
        guard content.count > 512 else { return nil }
        let tailCount = min(4096, content.count)
        let tail = content.suffix(tailCount)
        if let runStart = degenerationRunStart(in: tail) {
            return String(content.prefix(content.count - tailCount)) + tail[..<runStart]
        }
        return sectionRepeatTrimmed(content)
    }

    /// Section-level repetition guard: catches the model regenerating a large
    /// earlier block (a heading + table + paragraphs) verbatim — distinct from
    /// `degenerationRunStart`, which only sees back-to-back short chunk loops.
    /// This matters most for the Gemma 4 family, which runs with
    /// `repetitionPenalty = nil` (mlx-swift-lm #258 crash) and therefore has no
    /// sampling-level protection at all. Returns the content truncated at the
    /// point the repeated block began; nil when clean.
    ///
    /// A repeat is only declared when a ≥120-char anchor from the live tail
    /// matches an earlier passage AND the match runs ≥500 chars AND continues
    /// right up to the live end (i.e. the model is looping NOW — a completed,
    /// intentional quotation of earlier content does not fire the guard).
    static func sectionRepeatTrimmed(_ content: String) -> String? {
        guard content.count > 2000 else { return nil }
        let tailCount = min(1200, content.count / 2)
        let anchorLength = 120
        let minMatch = 500

        let tailStart = content.index(content.endIndex, offsetBy: -tailCount)
        let tail = content[tailStart...]
        let anchor = tail.prefix(anchorLength)
        guard anchor.count == anchorLength else { return nil }

        let earlier = content[..<tailStart]
        var searchStart = earlier.startIndex
        while let hit = earlier.range(of: anchor, range: searchStart..<earlier.endIndex) {
            // Forward-match the earlier passage against the live tail.
            var i = hit.lowerBound
            var j = tailStart
            var matched = 0
            while i < tailStart, j < content.endIndex, content[i] == content[j] {
                i = content.index(after: i)
                j = content.index(after: j)
                matched += 1
            }
            if matched >= minMatch, j == content.endIndex {
                // Walk backward to the true start of the repeated block so the
                // original stays intact and only the duplicate is dropped. The
                // walk stops where the two passages diverge (the repeat's
                // start) or where the earlier passage's own start is reached.
                var backEarlier = hit.lowerBound
                var backLive = tailStart
                while backEarlier > content.startIndex, backLive > hit.lowerBound {
                    let prevEarlier = content.index(before: backEarlier)
                    let prevLive = content.index(before: backLive)
                    guard content[prevEarlier] == content[prevLive] else { break }
                    backEarlier = prevEarlier
                    backLive = prevLive
                }
                return String(content[..<backLive])
            }
            searchStart = earlier.index(after: hit.lowerBound)
        }
        return nil
    }

    // MARK: - Vision Proxy

    /// Generate a short text description for an image using a FastVLM vision model.
    /// This lets non-vision models receive a compressed image description instead
    /// of raw pixels. The proxy model is loaded through the same residency cache as
    /// the main model, so it stays resident if the budget allows, and it uses a
    /// separate prompt cache key so captioning never contaminates the main chat's KV cache.
    @MainActor
    func captionWithFastVLM(
        proxyModel: MaestroModel,
        image: UserInput.Image,
        prompt: String,
        maxTokens: Int = 128
    ) async throws -> String {
        ModelActivitySampler.shared.register(proxyModel, state: .loading)
        let container = try await loadModel(proxyModel)
        ModelActivitySampler.shared.register(proxyModel, state: .idle)

        let chat: [Chat.Message] = [.user(prompt, images: [image])]
        let input = UserInput(chat: chat, tools: nil)

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: proxyModel.maxKVSize,
            temperature: 0.3,
            topP: 0.9,
            repetitionPenalty: 1.0,
            prefillStepSize: 512)

        // Dedicated session key isolates the proxy cache from the main model's cache.
        let sessionKey = "vision-proxy::\(proxyModel.id)"
        nonisolated(unsafe) let capturedInput = input
        nonisolated(unsafe) let pc = cache(forSession: sessionKey)
        let rngState = MLXRandom.RandomState(
            seed: DispatchTime.now().uptimeNanoseconds)

        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: capturedInput)
            let fullTokens = lmInput.text.tokens.asArray(Int.self)
            let hasUsableCache = pc.isReady
                && pc.modelID == proxyModel.id
                && !pc.caches.isEmpty
            var prefix = 0
            var canReuse = false
            if hasUsableCache {
                let minOffset = pc.caches.map { $0.offset }.min() ?? 0
                let base = MLXInferenceEngine.commonPrefixLength(pc.tokens, fullTokens)
                // Pure append: the whole previous prompt is a prefix of the new chat, so
                // the tokens generated last round (cache offset − stored prompt) are the
                // assistant turn that immediately follows — reusable with NO trim. This is
                // the only way non-trimmable MoE caches can ever be reused across rounds;
                // without it every round re-prefills the entire conversation.
                let pureAppend = !pc.tokens.isEmpty
                    && base == pc.tokens.count
                    && minOffset >= pc.tokens.count
                prefix = pureAppend
                    ? min(minOffset, fullTokens.count - 1)
                    : min(base, minOffset, fullTokens.count - 1)
                if prefix < 0 { prefix = 0 }
                // See note above: only require trimmability when a trim is actually
                // needed (diverged conversation); pure appends reuse regardless.
                canReuse = !(prefix < minOffset) || pc.caches.allSatisfy { $0.isTrimmable }
            }
            let inputForGen: LMInput
            let cacheForGen: [KVCache]
            if canReuse && prefix > 0 {
                for c in pc.caches { let amount = c.offset - prefix; if amount > 0 { c.trim(amount) } }
                let deltaInts = Array(fullTokens[prefix...]).map { Int32($0) }
                // Keep delta tokens 1-D. mlx-swift-lm's LLMModel.prepare and TokenIterator
                // internally add the batch axis via .newAxis; passing a 2-D array here
                // makes chunking slice the wrong axis and feeds the model 3-D/1-D inputs
                // instead of 2-D [batch, sequence], crashing in convertToToken's subscript.
                let deltaArray = MLXArray(deltaInts)
                inputForGen = LMInput(text: .init(tokens: deltaArray))
                cacheForGen = pc.caches
            } else {
                let fresh = context.model.newCache(parameters: parameters)
                pc.caches = fresh
                inputForGen = lmInput
                cacheForGen = fresh
            }
            pc.tokens = fullTokens
            pc.modelID = proxyModel.id
            pc.isReady = true
            return try withError {
                try withRandomState(rngState) {
                    try MLXLMCommon.generate(
                        input: inputForGen, cache: cacheForGen,
                        parameters: parameters, context: context)
                }
            }
        }

        var content = ""
        ProcessResourceSampler.shared.startGeneration()
        ModelActivitySampler.shared.startGeneration(id: proxyModel.id)
        for await generation in stream {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let chunk):
                ProcessResourceSampler.shared.recordToken()
                ModelActivitySampler.shared.recordToken(id: proxyModel.id)
                content += chunk
            case .info, .toolCall: break
            }
        }
        ProcessResourceSampler.shared.stopGeneration()
        ModelActivitySampler.shared.stopGeneration(id: proxyModel.id)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Control

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        ProcessResourceSampler.shared.stopGeneration()
        if case .generating = state {
            state = .idle
        }
    }

    /// Report generation throughput from the agentic backend (the in-process
    /// generation round) so the status bar reflects it.
    func reportExternalTokensPerSecond(_ tps: Double) {
        tokensPerSecond = tps
    }

    func unloadModel(_ modelID: String) {
        modelCache.removeValue(forKey: modelID)
        resident.removeValue(forKey: modelID)
        legacyPromptCache.reset()
        promptCaches.removeAll()
        clearMLXCaches()
        if case .ready(let name) = state, name == modelID {
            state = .idle
        }
    }

    func unloadAll() {
        modelCache.removeAll()
        resident.removeAll()
        legacyPromptCache.reset()
        promptCaches.removeAll()
        clearMLXCaches()
        state = .idle
    }

    /// Length of the shared leading run of two token sequences.
    fileprivate nonisolated static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }
}

// MARK: - Residency readout / wired policy

/// One resident model for the Settings readout.
struct ResidentModelReadout: Identifiable, Hashable {
    let id: String
    let name: String
    let gb: Int
}

/// Wired-memory policy that raises the process wired limit to cover the active
/// resident set during generation (so a large model like the 122B stays wired and
/// fast even with other models resident), capped at the resident budget. Unlike
/// `WiredSumPolicy` it does not implement `canAdmit`, so it never blocks admission
/// — concurrent agent generations aren't serialized; the cap still bounds total
/// wiring.
private struct ResidencyWiredPolicy: WiredMemoryPolicy, Hashable, Sendable {
    let capBytes: Int
    func limit(baseline: Int, activeSizes: [Int]) -> Int {
        min(baseline + activeSizes.reduce(0, +), capBytes)
    }
}

// MARK: - Prompt KV cache holder

/// Reference-type holder for a prompt KV cache and the exact token sequence it
/// represents. A class (not a struct) so it can be shared by reference into the
/// model container's isolated `perform` closure. One instance is kept per agent
/// session (`MLXInferenceEngine.promptCaches`), so concurrent agents never share
/// a `PromptCache` and each round mutates only its own.
private final class PromptCache {
    var caches: [KVCache] = []
    /// The full prompt token sequence most recently fed (prefix of what the
    /// cache holds, modulo trailing generated tokens).
    var tokens: [Int] = []
    var modelID: String = ""
    var isReady = false

    func reset() {
        caches = []
        tokens = []
        modelID = ""
        isReady = false
    }
}
