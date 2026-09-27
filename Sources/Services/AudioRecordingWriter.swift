import Foundation

/// Appends floating-point audio samples to a WAV file as they arrive from the
/// realtime transcriber.
///
/// ## Concurrency model
///
/// A single dedicated serial queue owns *all* file state. The previous
/// implementation was an `actor` and callers reached it from an
/// `AVAudioEngine` tap by spawning an unstructured `Task` per buffer:
///
/// ```swift
/// Task { try? await writer.appendSlice(samples) }   // old, buggy
/// ```
///
/// That was wrong in three ways, all of which silently corrupted recordings:
///
/// 1. **No ordering guarantee.** `Task` gives no FIFO ordering, so slice N+1
///    could be persisted before slice N, scrambling the WAV in time.
/// 2. **Unbounded task growth.** The tap fires every `bufferSize` frames; a
///    disk write per task outran the callback rate and the queue grew without
///    backpressure.
/// 3. **A teardown race.** `close()` was enqueued as *another* `Task`, so it
///    could close the handle while `appendSlice` calls were still in flight.
///    The late writes threw, were discarded by `try?`, and the WAV header was
///    stamped with a stale `totalSamples`.
///
/// The failure was invisible because the level meters and the elapsed timer are
/// computed in the tap itself and pushed to the main actor — they reported the
/// incoming signal perfectly while nothing reached disk.
///
/// Use `enqueue(slice:)` from a realtime thread: it is O(1), non-blocking, and
/// never allocates a task. The serial queue restores ordering, and `close()`
/// drains it before writing the header so nothing is lost on teardown.
final class AudioRecordingWriter: @unchecked Sendable {
    let fileURL: URL
    private let sampleRate: Double
    private let channels: UInt16
    private let queue = DispatchQueue(label: "com.woodseedigi.SwiftMaestro.audio-recording-writer")

    private var fileHandle: FileHandle?
    private var lastSampleCount: Int = 0
    private var totalSamples: Int = 0
    /// First asynchronous write failure, surfaced by `close()` so a truncated
    /// recording reports itself instead of looking like a successful one.
    private var writeFailure: Error?

    init(fileURL: URL, sampleRate: Double = 16000, channels: UInt16 = 1) {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func open() throws {
        try queue.sync { try openLocked() }
    }

    /// Realtime-safe entry point for an `AVAudioEngine` tap. Copies and
    /// enqueues in O(1); never blocks the audio thread on disk I/O.
    func enqueue(slice samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in appendSliceLocked(samples) }
    }

    /// Cumulative-buffer variant for WhisperKit, which hands over a *growing*
    /// array and expects only the new tail to be written. Ordering against
    /// `enqueue(slice:)` is preserved because everything runs on the same
    /// serial queue.
    ///
    /// - Note: Do not mix this with `enqueue(slice:)` on the same writer.
    func append(samples: [Float]) throws {
        var thrown: Error?
        queue.sync {
            do { try appendLocked(samples) }
            catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    /// Drains any pending writes, then stamps the header. Ordering is
    /// guaranteed: `queue.sync` waits for every previously enqueued block.
    func close() throws {
        var thrown: Error?
        queue.sync {
            do { try finishLocked() }
            catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    // MARK: - Queue-confined implementation

    private func openLocked() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        fm.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw AudioRecordingWriterError.cannotOpenFile
        }
        fileHandle = handle
        lastSampleCount = 0
        totalSamples = 0
        writeFailure = nil
        // Write a placeholder WAV header; it will be rewritten on close.
        handle.write(Data(WAVHeader.wavHeader(totalSamples: 0, sampleRate: UInt32(sampleRate), channels: channels)))
    }

    /// Self-contained tap buffer: every sample in the array is written.
    private func appendSliceLocked(_ samples: [Float]) {
        guard let handle = fileHandle else {
            record(AudioRecordingWriterError.fileNotOpen)
            return
        }
        guard !samples.isEmpty else { return }
        totalSamples += samples.count
        do {
            try handle.write(contentsOf: Self.pcm16Data(from: samples))
        } catch {
            record(error)
        }
    }

    private func appendLocked(_ samples: [Float]) throws {
        guard let handle = fileHandle else { throw AudioRecordingWriterError.fileNotOpen }
        let newSamples = Array(samples.suffix(from: min(lastSampleCount, samples.count)))
        guard !newSamples.isEmpty else { return }
        lastSampleCount = samples.count
        totalSamples += newSamples.count
        try handle.write(contentsOf: Self.pcm16Data(from: newSamples))
    }

    private func finishLocked() throws {
        guard let handle = fileHandle else { throw AudioRecordingWriterError.fileNotOpen }
        // Always finalise the file, even if a queued write failed, so the
        // recording stays a valid, playable WAV rather than an orphan.
        try handle.seek(toOffset: 0)
        let header = WAVHeader.wavHeader(totalSamples: totalSamples, sampleRate: UInt32(sampleRate), channels: channels)
        try handle.write(contentsOf: Data(header))
        try handle.close()
        fileHandle = nil
        if let writeFailure { throw writeFailure }
    }

    private func record(_ error: Error) {
        if writeFailure == nil { writeFailure = error }
    }

    /// Float → little-endian signed 16-bit PCM, with clipping.
    private static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            var pcm = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &pcm) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Reads a WAV file's sample rate from its header and computes duration
    /// from the actual file size. Used to recover orphaned recordings after a
    /// crash (a killed mid-write header may claim 0 samples, but the file size
    /// tells the truth).
    static func recoveredDuration(fileURL: URL) -> TimeInterval {
        guard let handle = try? FileHandle(forReadingFrom: fileURL),
              let header = try? handle.read(upToCount: 44), header.count >= 44,
              header.prefix(4).elementsEqual("RIFF".utf8) else {
            return 0
        }
        try? handle.close()
        // Sample rate is a little-endian UInt32 at byte offset 24. Assembled
        // byte-by-byte — Data isn't guaranteed aligned for a typed load.
        let sampleRate = UInt32(header[24]) | UInt32(header[25]) << 8
            | UInt32(header[26]) << 16 | UInt32(header[27]) << 24
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let dataBytes = max(0, fileSize - 44)
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(dataBytes / 2) / TimeInterval(sampleRate) // 16-bit mono
    }
}

enum AudioRecordingWriterError: Error {
    case cannotOpenFile
    case fileNotOpen
}

// MARK: - WAV header helper

private enum WAVHeader {
    static func wavHeader(totalSamples: Int, sampleRate: UInt32, channels: UInt16) -> [UInt8] {
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(channels * bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(bytesPerSample)
        let blockAlign = bytesPerSample
        let dataSize = UInt32(totalSamples * Int(bytesPerSample))
        let riffSize = 36 + dataSize

        var header = [UInt8]()
        header.append(contentsOf: "RIFF".utf8Bytes)
        header.append(contentsOf: riffSize.littleEndianBytes)
        header.append(contentsOf: "WAVE".utf8Bytes)
        header.append(contentsOf: "fmt ".utf8Bytes)
        header.append(contentsOf: UInt32(16).littleEndianBytes)
        header.append(contentsOf: UInt16(1).littleEndianBytes) // PCM
        header.append(contentsOf: channels.littleEndianBytes)
        header.append(contentsOf: sampleRate.littleEndianBytes)
        header.append(contentsOf: byteRate.littleEndianBytes)
        header.append(contentsOf: blockAlign.littleEndianBytes)
        header.append(contentsOf: bitsPerSample.littleEndianBytes)
        header.append(contentsOf: "data".utf8Bytes)
        header.append(contentsOf: dataSize.littleEndianBytes)
        return header
    }
}

private extension String {
    var utf8Bytes: [UInt8] { Array(utf8) }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
