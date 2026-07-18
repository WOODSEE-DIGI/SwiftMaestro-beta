import Foundation

/// Fast, resumable Hugging Face Hub downloads using a local Python helper.
///
/// `swift-transformers` / `HubApi.snapshot()` is convenient but single-threaded and
/// does not resume interrupted downloads. This service uses `huggingface_hub`
/// (with `hf-transfer` / Xet acceleration when available) and reports live progress.
@MainActor
final class HuggingFaceDownloadService: ObservableObject {

    static let shared = HuggingFaceDownloadService()

    /// Per-download state, keyed by destination directory path. A dictionary
    /// (not scalar `progress`/`isRunning`/`currentRepo` properties) so
    /// multiple models can download concurrently without one download's
    /// state overwriting another's — a real bug found in testing: starting a
    /// second model's download while the first was still running caused the
    /// first to appear to stop, because both were tracked through the same
    /// single set of published properties.
    @Published private(set) var activeDownloads: [String: Double] = [:]
    private var processes: [String: Process] = [:]

    private init() {}

    /// Live progress (0...1) for a specific destination directory, or `nil`
    /// if nothing is downloading there right now.
    func progress(forDestination path: String) -> Double? {
        activeDownloads[path]
    }

    /// Download a repo to a local directory. If `localDir` is omitted, the repo is
    /// placed under the current model root (`ModelCatalog.modelsRoot`) using the repo
    /// name as the directory.
    func download(
        repoID: String,
        revision: String = "main",
        localDir: String? = nil,
        allowPatterns: [String]? = nil,
        ignorePatterns: [String]? = nil,
        token: String? = nil
    ) async throws -> URL {
        let destination: URL
        if let localDir {
            destination = URL(fileURLWithPath: localDir)
        } else {
            let root = URL(fileURLWithPath: ModelCatalog.modelsRoot)
            let repoName = repoID.components(separatedBy: "/").last ?? repoID
            destination = root.appendingPathComponent(repoName, isDirectory: true)
        }
        let key = destination.path
        NSLog("[HF DOWNLOAD] starting download: %@ -> %@", repoID, key)

        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let request: [String: Any] = [
            "repo_id": repoID,
            "local_dir": destination.path,
            "revision": revision,
            "allow_patterns": allowPatterns as Any,
            "ignore_patterns": ignorePatterns as Any,
            "hf_token": token as Any,
        ]

        activeDownloads[key] = 0
        defer { activeDownloads[key] = nil }

        NSLog("[HF DOWNLOAD] preparing helper...")
        let (scriptPath, pythonExecutable) = try await prepareHelper()
        NSLog("[HF DOWNLOAD] helper ready: python=%@ script=%@", pythonExecutable, scriptPath)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonExecutable)
            process.arguments = [scriptPath]
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["HF_XET_HIGH_PERFORMANCE"] = "1"
            if let token {
                process.environment?["HF_TOKEN"] = token
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                Task { @MainActor in
                    self.processes[key] = nil
                    if proc.terminationStatus != 0 {
                        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
                        continuation.resume(throwing: DownloadError.failed(status: Int(proc.terminationStatus), stderr: err))
                    } else {
                        continuation.resume(returning: destination)
                    }
                }
            }

            do {
                NSLog("[HF DOWNLOAD] launching python process...")
                try process.run()
                self.processes[key] = process
                NSLog("[HF DOWNLOAD] python process launched (pid=%d)", process.processIdentifier)
                // Feed the request JSON to stdin and close it.
                let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
                stdinPipe.fileHandleForWriting.write(data)
                try? stdinPipe.fileHandleForWriting.close()

                // Parse stdout for progress updates.
                Task.detached(priority: .utility) {
                    let handle = stdoutPipe.fileHandleForReading
                    while let line = await handle.readLine() {
                        await MainActor.run {
                            self.handleProgressLine(line, key: key)
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Cancel the download writing to `destination`, if any. No-op if
    /// nothing is currently downloading there.
    func cancel(destination path: String) {
        if let process = processes[path], process.isRunning {
            process.terminate()
        }
        processes[path] = nil
        activeDownloads[path] = nil
    }

    // MARK: - Helper script

    /// Ensure the Python helper exists on disk and return (scriptPath, pythonExecutable).
    private func prepareHelper() async throws -> (String, String) {
        try await PythonVenvService.shared.ensureVisionDependencies()
        let pythonExecutable = PythonVenvService.shared.pythonExecutable.path

        let helperDir = SwiftMaestroPaths.logsDir.appendingPathComponent("helpers", isDirectory: true)
        try? FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        let scriptPath = helperDir.appendingPathComponent("hf_download_helper.py").path

        // Always overwrite the helper so updates are picked up immediately.
        try helperScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        return (scriptPath, pythonExecutable)
    }

    private func handleProgressLine(_ line: String, key: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        switch obj["type"] as? String {
        case "progress":
            if let completed = obj["completed"] as? Double,
               let total = obj["total"] as? Double,
               total > 0 {
                activeDownloads[key] = completed / total
            }
        case "complete":
            activeDownloads[key] = 1
        case "error":
            let msg = obj["message"] as? String ?? "download error"
            NSLog("[HF DOWNLOAD] error: \(msg)")
        default:
            break
        }
    }

    enum DownloadError: LocalizedError {
        case failed(status: Int, stderr: String)

        var errorDescription: String? {
            switch self {
            case .failed(let status, let stderr):
                return "HuggingFace download failed (exit \(status)): \(stderr)"
            }
        }
    }

    // MARK: - Embedded helper script

    /// Robust Python downloader that uses `curl` for actual file transfer.
    ///
    /// `huggingface_hub.snapshot_download()` is reliable for many repos, but on some
    /// Xet-hosted large files it hangs silently. This helper first fetches the file list
    /// via the HuggingFace API, then downloads each file with `curl` (which supports
    /// resume, HTTP/2, and the HF auth redirect), and falls back to `huggingface_hub`
    /// for metadata-only operations if curl is unavailable.
    private let helperScript = """
#!/usr/bin/env python3
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    from huggingface_hub import HfApi
    from huggingface_hub.utils import build_hf_headers
except ImportError as e:
    print(json.dumps({"type": "error", "message": "huggingface_hub not installed: " + str(e)}), flush=True)
    sys.exit(1)


def _print_json(obj):
    print(json.dumps(obj), flush=True)


def _curl_available():
    try:
        subprocess.run(["curl", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except Exception:
        return False


def _file_matches(path, patterns):
    if not patterns:
        return True
    return any(fnmatch.fnmatch(path, p) for p in patterns)


def _download_with_curl(url, dest, headers):
    cmd = ["curl", "-L", "-C", "-", "--fail", "--silent", "--show-error"]
    for k, v in headers.items():
        cmd.extend(["-H", f"{k}: {v}"])
    cmd.extend(["-o", str(dest), url])
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"curl failed ({result.returncode}): {result.stderr}")


def _download_with_hf_hub(repo_id, filename, dest, token, revision):
    from huggingface_hub import hf_hub_download
    tmp_path = hf_hub_download(
        repo_id=repo_id,
        filename=filename,
        revision=revision,
        token=token,
        cache_dir=str(dest.parent / ".cache_hf"),
        local_dir_use_symlinks=False,
    )
    os.replace(tmp_path, dest)


def _fetch_file_list(api, repo_id, revision, token, allow_patterns, ignore_patterns):
    info = api.repo_info(repo_id=repo_id, revision=revision, token=token)
    files = []
    for sibling in info.siblings or []:
        name = sibling.rfilename
        if name in {".gitattributes"}:
            pass
        size = sibling.size or 0
        if allow_patterns and not _file_matches(name, allow_patterns):
            continue
        if ignore_patterns and _file_matches(name, ignore_patterns):
            continue
        files.append({"name": name, "size": size})
    return files


def download(req: dict):
    repo_id = req["repo_id"]
    local_dir = Path(req["local_dir"]).expanduser()
    local_dir.mkdir(parents=True, exist_ok=True)
    revision = req.get("revision") or "main"
    allow_patterns = req.get("allow_patterns")
    ignore_patterns = req.get("ignore_patterns")
    token = req.get("hf_token") or os.environ.get("HF_TOKEN")

    api = HfApi()
    headers = build_hf_headers(token=token)

    _print_json({"type": "start", "repo_id": repo_id, "local_dir": str(local_dir)})

    try:
        files = _fetch_file_list(api, repo_id, revision, token, allow_patterns, ignore_patterns)
    except Exception as e:
        _print_json({"type": "error", "message": f"Failed to list repo files: {e}"})
        sys.exit(1)

    total_size = sum(f["size"] for f in files)
    downloaded = 0
    use_curl = _curl_available()

    for idx, file in enumerate(files):
        name = file["name"]
        dest = local_dir / name
        dest.parent.mkdir(parents=True, exist_ok=True)

        if dest.exists() and dest.stat().st_size == file["size"] and file["size"] > 0:
            downloaded += file["size"]
            _print_json({"type": "progress", "file": name, "completed": downloaded, "total": total_size})
            continue

        _print_json({"type": "file_start", "file": name, "index": idx + 1, "total_files": len(files)})

        url = f"https://huggingface.co/{repo_id}/resolve/{revision}/{name}"
        try:
            if use_curl:
                _download_with_curl(url, dest, headers)
            else:
                _download_with_hf_hub(repo_id, name, dest, token, revision)
        except Exception as e:
            _print_json({"type": "error", "message": f"Failed to download {name}: {e}"})
            sys.exit(1)

        if file["size"] > 0 and dest.stat().st_size != file["size"]:
            _print_json({"type": "error", "message": f"Size mismatch for {name}: expected {file['size']}, got {dest.stat().st_size}"})
            sys.exit(1)

        downloaded += file["size"]
        _print_json({"type": "progress", "file": name, "completed": downloaded, "total": total_size})

    _print_json({"type": "complete", "repo_id": repo_id, "local_dir": str(local_dir)})


if __name__ == "__main__":
    try:
        req = json.load(sys.stdin)
        download(req)
    except Exception as e:
        _print_json({"type": "error", "message": str(e)})
        sys.exit(1)
"""
}

// MARK: - FileHandle async read line

private extension FileHandle {
    func readLine() async -> String? {
        var buffer = Data()
        while true {
            let chunk = readData(ofLength: 1)
            if chunk.isEmpty { return nil }
            if chunk.first == UInt8(ascii: "\n") {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}
