import SwiftUI
import Photos

// MARK: - Photos view

/// Native Apple Photos panel: browse albums and view recent asset metadata and
/// thumbnails.
enum PhotosViewMode: String, CaseIterable, Identifiable, Codable {
    case list
    case grid
    case largeGrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        case .largeGrid: return "Large Grid"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .largeGrid: return "square.grid.3x2"
        }
    }

    var columns: [GridItem] {
        switch self {
        case .list:
            return [GridItem(.flexible())]
        case .grid:
            return [GridItem(.adaptive(minimum: 120, maximum: 160))]
        case .largeGrid:
            return [GridItem(.adaptive(minimum: 200, maximum: 260))]
        }
    }

    var thumbnailSize: CGFloat {
        switch self {
        case .list: return 96
        case .grid: return 160
        case .largeGrid: return 260
        }
    }
}

struct PhotosView: View {
    @Environment(ApplePhotosService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var albums: [ApplePhotosAlbum] = []
    @State private var assets: [ApplePhotosAsset] = []
    @State private var selectedAlbumID: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var assetLimit = 25
    @AppStorage("photos.viewMode") private var viewMode: PhotosViewMode = .list
    @State private var selectedAssetID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            HStack(spacing: 12) {
                albumList
                    .frame(width: 220)
                Divider()
                assetList
            }
        }
        .task {
            await requestAndLoad()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Photos")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Picker("View", selection: $viewMode) {
                    ForEach(PhotosViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Text("Limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Limit", selection: $assetLimit) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .onChange(of: assetLimit) { _, _ in
                    Task { await loadAssets() }
                }
                Button {
                    Task { await requestAndLoad() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    service.openPhotos()
                } label: {
                    Label("Open Photos", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    // MARK: - Album list

    private var albumList: some View {
        VStack(spacing: 0) {
            Text("Albums")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            List(selection: $selectedAlbumID) {
                Section("Library") {
                    Text("All Photos")
                        .tag(String?.none)
                }
                Section("Albums") {
                    ForEach(albums) { album in
                        HStack {
                            Text(album.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(album.assetCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(String?.some(album.id))
                    }
                }
            }
            .onChange(of: selectedAlbumID) { _, _ in
                Task { await loadAssets() }
            }
        }
    }

    // MARK: - Asset list

    private var assetList: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if assets.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.stack",
                    description: Text("Grant Photos access and select an album.")
                )
                Spacer()
            } else {
                Group {
                    switch viewMode {
                    case .list:
                        List {
                            Section(header: Text("\(assets.count) assets")) {
                                ForEach(assets) { asset in
                                    assetRow(asset)
                                }
                            }
                        }
                    case .grid, .largeGrid:
                        gridAssetList
                    }
                }
            }
        }
    }

    private var gridAssetList: some View {
        ScrollView {
            LazyVGrid(columns: viewMode.columns, spacing: 16) {
                ForEach(assets) { asset in
                    gridAssetCell(asset)
                }
            }
            .padding()
        }
    }

    private func gridAssetCell(_ asset: ApplePhotosAsset) -> some View {
        VStack(spacing: 6) {
            AssetThumbnail(assetID: asset.id, size: viewMode.thumbnailSize)
                .frame(width: viewMode.thumbnailSize, height: viewMode.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selectedAssetID == asset.id ? Color.accentColor : Color.clear, lineWidth: 3)
                )
                .onTapGesture {
                    selectedAssetID = asset.id
                }
                .contextMenu {
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(asset.id, forType: .string)
                    }
                }

            Text(asset.filename ?? "(untitled)")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Text(asset.mediaType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let creationDate = asset.creationDate {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(creationDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func assetRow(_ asset: ApplePhotosAsset) -> some View {
        HStack(spacing: 10) {
            AssetThumbnail(assetID: asset.id)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(asset.filename ?? "(untitled)")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(asset.mediaType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let creationDate = asset.creationDate {
                        Text(creationDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let latitude = asset.latitude, let longitude = asset.longitude {
                    Text("\(latitude, specifier: "%.5f"), \(longitude, specifier: "%.5f")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.id, forType: .string)
            }
        }
    }

    // MARK: - Loading

    private func requestAndLoad() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        await service.requestAuthorization()
        service.refreshStatus()

        if service.status == .authorized || service.status == .limited {
            albums = await service.fetchAlbums()
            await loadAssets()
        } else {
            errorMessage = "Photos access was denied. Grant it in System Settings → Privacy & Security → Photos."
        }
    }

    private func loadAssets() async {
        isLoading = true
        defer { isLoading = false }
        assets = await service.fetchAssets(
            inAlbumLocalIdentifier: selectedAlbumID,
            limit: assetLimit
        )
    }
}

// MARK: - Thumbnail loader

/// Loads a small thumbnail for a Photos asset via `PHImageManager`.
struct AssetThumbnail: View {
    let assetID: String
    var size: CGFloat = 96

    @State private var thumbnail: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .task(id: assetID + "\(size)") {
            await loadThumbnail()
        }
        .onDisappear {
            if let requestID = requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return
        }

        let size = CGSize(width: size, height: size)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        await withCheckedContinuation { continuation in
            let id = PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let image = image {
                    self.thumbnail = image
                }
                continuation.resume()
            }
            self.requestID = id
        }
    }
}

// MARK: - Preview

#Preview {
    PhotosView()
        .environment(ApplePhotosService())
        .environment(ThemeStore())
}
