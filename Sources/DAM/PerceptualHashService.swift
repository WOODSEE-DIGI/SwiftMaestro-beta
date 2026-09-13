import Foundation
import Accelerate
import CoreImage
import AppKit

// MARK: - Perceptual Hash Service

/// Generates 64-bit pHashes for images using a classic DCT-based algorithm.
///
/// The hash is robust to minor resizing, compression, and colour shifts, which
/// makes it useful for finding near-duplicate images (same shot exported at
/// different resolutions, social crops, etc.). It is **not** a cryptographic
/// hash — visually different images can collide, and two images with the same
/// pHash may still differ meaningfully.
actor PerceptualHashService {
    static let shared = PerceptualHashService()

    private let hashSize = 8
    private let dctSize = 32

    private init() {}

    /// Computes a 16-character hex pHash for an image file, or nil if the file
    /// cannot be decoded as an image.
    func hash(for path: String) async -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let cgImage = thumbnailCGImage(at: path, maxSize: dctSize)
        else { return nil }

        guard let pixels = gray32x32Pixels(from: cgImage) else { return nil }

        do {
            let dct = try dct2D(pixels: pixels, size: dctSize)
            return hash(from: dct, size: hashSize)
        } catch {
            return nil
        }
    }

    // MARK: - Thumbnail decoding

    /// Decodes the first image at `path` and resizes it to at most `maxSize`
    /// on each axis. The result is then drawn into a 32×32 grayscale context.
    private func thumbnailCGImage(at path: String, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws any CGImage into a 32×32 8-bit grayscale buffer and returns the
    /// raw pixel values in row-major order.
    private func gray32x32Pixels(from image: CGImage) -> [Float]? {
        let size = dctSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size)
        var pixels: [Float] = []
        pixels.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                pixels.append(Float(bytes[y * size + x]))
            }
        }
        return pixels
    }

    // MARK: - DCT

    /// Computes the 2D DCT-II of a square pixel matrix using Accelerate.
    private func dct2D(pixels: [Float], size: Int) throws -> [Float] {
        guard let setup = vDSP_DCT_CreateSetup(nil, vDSP_Length(size), .II) else {
            throw PerceptualHashError.dctSetupFailed
        }

        // Row DCT.
        var rowDCT = [Float](repeating: 0, count: size * size)
        var rowInput = [Float](repeating: 0, count: size)
        var rowOutput = [Float](repeating: 0, count: size)

        for y in 0..<size {
            for x in 0..<size {
                rowInput[x] = pixels[y * size + x]
            }
            vDSP_DCT_Execute(setup, &rowInput, &rowOutput)
            for x in 0..<size {
                rowDCT[y * size + x] = rowOutput[x]
            }
        }

        // Column DCT.
        var dct = [Float](repeating: 0, count: size * size)
        var colInput = [Float](repeating: 0, count: size)
        var colOutput = [Float](repeating: 0, count: size)

        for x in 0..<size {
            for y in 0..<size {
                colInput[y] = rowDCT[y * size + x]
            }
            vDSP_DCT_Execute(setup, &colInput, &colOutput)
            for y in 0..<size {
                dct[y * size + x] = colOutput[y]
            }
        }

        return dct
    }

    // MARK: - Hashing

    /// Builds a 64-bit hash from the top-left `size × size` DCT coefficients.
    private func hash(from dct: [Float], size: Int) -> String {
        let regionSize = size
        var lowFreq: [Float] = []
        lowFreq.reserveCapacity(regionSize * regionSize)

        for y in 0..<regionSize {
            for x in 0..<regionSize {
                lowFreq.append(dct[y * dctSize + x])
            }
        }

        let sorted = lowFreq.sorted()
        let median = sorted[sorted.count / 2]

        var hashValue: UInt64 = 0
        for (index, value) in lowFreq.enumerated() {
            if value > median {
                hashValue |= (1 << UInt64(index))
            }
        }

        return String(format: "%016llx", hashValue)
    }
}

// MARK: - Errors

enum PerceptualHashError: Error {
    case dctSetupFailed
}
