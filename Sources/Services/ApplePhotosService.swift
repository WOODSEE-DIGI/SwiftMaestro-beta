import Foundation
import Photos
import AppKit

// MARK: - Apple Photos service

/// Bridges SwiftMaestro to the macOS Photos library via PhotoKit. Lists albums,
/// lists recent assets in an album, and returns asset metadata. Opening a
/// specific asset in Photos is done by activating the app; PhotoKit does not
/// expose a public URL scheme for individual items.
@Observable
@MainActor
final class ApplePhotosService {

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
        case limited
    }

    private(set) var status: AuthorizationStatus = .notDetermined
    private let imageManager = PHImageManager.default()

    // MARK: - Authorization

    func requestAuthorization() async {
        let value = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        status = mapStatus(value)
    }

    func refreshStatus() {
        status = mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private func mapStatus(_ value: PHAuthorizationStatus) -> AuthorizationStatus {
        switch value {
        case .notDetermined: return .notDetermined
        case .restricted: return .denied
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Albums

    func fetchAlbums() -> [ApplePhotosAlbum] {
        var results: [ApplePhotosAlbum] = []

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            results.append(ApplePhotosAlbum(from: collection))
        }

        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            results.append(ApplePhotosAlbum(from: collection))
        }

        return results
    }

    // MARK: - Assets

    func fetchAssets(inAlbumLocalIdentifier albumID: String? = nil, limit: Int = 50) -> [ApplePhotosAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let assets: PHFetchResult<PHAsset>
        if let albumID = albumID, !albumID.isEmpty,
           let collection = PHAssetCollection.fetchAssetCollections(
               withLocalIdentifiers: [albumID], options: nil).firstObject {
            assets = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }

        var results: [ApplePhotosAsset] = []
        assets.enumerateObjects { asset, _, _ in
            results.append(ApplePhotosAsset(from: asset))
        }
        return results
    }

    // MARK: - Open Photos app

    func openPhotos() -> Bool {
        AppleMapsService.openApplication(bundleID: "com.apple.Photos")
    }

    // MARK: - Export helper (optional, for future use)
    ///
    /// Request a file-backed image for an asset. Because the agent tools are
    /// currently text-only, this is exposed as a method but not yet advertised
    /// as a tool. It can be wired later for image-analysis workflows.

    func requestImageFile(
        for localIdentifier: String,
        targetSize: CGSize = CGSize(width: 1024, height: 1024),
        contentMode: PHImageContentMode = .default
    ) async throws -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data = data else {
                    continuation.resume(returning: nil)
                    return
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("swiftmaestro-photo-\(localIdentifier).jpg")
                do {
                    try data.write(to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Models

struct ApplePhotosAlbum: Sendable, Identifiable, Codable {
    let id: String
    let title: String
    let type: String
    let assetCount: Int

    init(from collection: PHAssetCollection) {
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "(untitled)"
        self.type = collection.assetCollectionType == .album ? "album" : "smartAlbum"
        // `estimatedAssetCount` returns NSNotFound (Int.max) for smart albums and
        // collections whose count is not cached. Compute the real count instead.
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        self.assetCount = PHAsset.fetchAssets(in: collection, options: fetchOptions).count
    }
}

struct ApplePhotosAsset: Sendable, Identifiable, Codable {
    let id: String
    let mediaType: String
    let creationDate: String?
    let modificationDate: String?
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let filename: String?

    init(from asset: PHAsset) {
        self.id = asset.localIdentifier
        self.mediaType = asset.mediaType.description
        self.creationDate = asset.creationDate?.iso8601
        self.modificationDate = asset.modificationDate?.iso8601
        self.latitude = asset.location?.coordinate.latitude
        self.longitude = asset.location?.coordinate.longitude
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.filename = asset.value(forKey: "filename") as? String
    }
}

// MARK: - Private helpers

private extension PHAssetMediaType {
    var description: String {
        switch self {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
}

private extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
