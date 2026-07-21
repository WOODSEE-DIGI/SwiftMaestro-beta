import Foundation

/// Appends floating-point audio samples to a WAV file as they arrive from the
/// realtime transcriber. Only writes the *new* samples since the last call so it
/// can be driven repeatedly on the same growing audio buffer.
actor AudioRecordingWriter {
    let fileURL: URL
    private let sampleRate: Double
    private let channels: UInt16
    private var fileHandle: FileHandle?
    private var lastSampleCount: Int = 0
    private var totalSamples: Int = 0

    init(fileURL: URL, sampleRate: Double = 16000, channels: UInt16 = 1) {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func open() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        fm.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw AudioRecordingWriterError.cannotOpenFile
        }
        fileHandle = handle
        // Write a placeholder WAV header; it will be rewritten on close.
        let header = WAVHeader.wavHeader(totalSamples: 0, sampleRate: UInt32(sampleRate), channels: channels)
        handle.write(Data(header))
    }

    func append(samples: [Float]) throws {
        guard let handle = fileHandle else { throw AudioRecordingWriterError.fileNotOpen }
        let newSamples = Array(samples.suffix(from: min(lastSampleCount, samples.count)))
        guard !newSamples.isEmpty else { return }
        lastSampleCount = samples.count
        totalSamples += newSamples.count
        let data = newSamples.withUnsafeBytes { buffer in
            var int16 = [Int16]()
            int16.reserveCapacity(newSamples.count)
            if let base = buffer.baseAddress?.assumingMemoryBound(to: Float.self) {
                for i in 0 ..< newSamples.count {
                    let clipped = max(-1.0, min(1.0, base[i]))
                    int16.append(Int16(clipped * Float(Int16.max)))
                }
            }
            return Data(bytes: int16, count: int16.count * MemoryLayout<Int16>.size)
        }
        handle.write(data)
    }

    func close() throws {
        guard let handle = fileHandle else { return }
        try handle.seek(toOffset: 0)
        let header = WAVHeader.wavHeader(totalSamples: totalSamples, sampleRate: UInt32(sampleRate), channels: channels)
        handle.write(Data(header))
        try handle.close()
        fileHandle = nil
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
