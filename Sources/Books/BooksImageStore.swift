import AppKit
import Foundation
import SwiftUI

// MARK: - MaestroBooks Image Store

/// Copies and resolves attached images for Books records (products, expenses,
/// suppliers, bills). Images live under Application Support so moving or
/// deleting the original file does not break the record.
enum BooksImageStore {
    /// Path relative to Application Support/SwiftMaestro, e.g.
    /// "Books/Images/expense-123-uuid.jpg".
    private static let relativeFolder = "Books/Images"

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
    }

    private static var directory: URL {
        appSupport.appendingPathComponent(relativeFolder, isDirectory: true)
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Resolves a stored relative path into a displayable file URL.
    static func url(for relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let url = appSupport.appendingPathComponent(relativePath, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Loads an NSImage from a stored relative path.
    static func image(for relativePath: String?) -> NSImage? {
        guard let url = url(for: relativePath) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Copies a user-selected image into the Books image folder. Returns the
    /// relative path stored in the record, or nil on failure.
    @discardableResult
    static func copyImage(
        from sourceURL: URL,
        recordType: String,
        recordID: Int64? = nil
    ) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        return copyImage(fromTemporaryData: data, filename: sourceURL.lastPathComponent, ext: ext, recordType: recordType, recordID: recordID)
    }

    /// Copies already-in-memory image data into the Books image folder.
    /// Used by the email importer before a record ID exists.
    @discardableResult
    static func copyImage(
        fromTemporaryData data: Data,
        filename: String,
        ext: String? = nil,
        recordType: String,
        recordID: Int64? = nil
    ) -> String? {
        do {
            try ensureDirectory()
            let resolvedExt = (ext ?? (filename as NSString).pathExtension).isEmpty ? "jpg" : (ext ?? (filename as NSString).pathExtension)
            let idSuffix = recordID.map { "\($0)-" } ?? ""
            let name = "\(recordType)-\(idSuffix)\(UUID().uuidString).\(resolvedExt)"
            let dest = directory.appendingPathComponent(name)
            try data.write(to: dest, options: .atomic)
            return relativeFolder + "/" + name
        } catch {
            NSLog("[BooksImageStore] copy failed: %@", String(describing: error))
            return nil
        }
    }

    /// Removes the stored image file (and its thumbnail sidecar if any).
    static func deleteImage(for relativePath: String?) {
        guard let url = url(for: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns a reasonable starting directory for an NSOpenPanel when the
    /// user wants to pick an image from MaestroDAM.
    static var damSuggestedDirectory: URL {
        appSupport.appendingPathComponent("DAM", isDirectory: true)
    }
}

// MARK: - SwiftUI helpers

/// Small, fixed-size thumbnail used in list rows.
struct BooksImageThumbnail: View {
    let relativePath: String?
    let fallback: String
    let size: CGFloat

    init(relativePath: String?, fallback: String = "photo", size: CGFloat = 36) {
        self.relativePath = relativePath
        self.fallback = fallback
        self.size = size
    }

    var body: some View {
        Group {
            if let image = BooksImageStore.image(for: relativePath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallback)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared image attachment section for record editors.
struct BooksImageAttachmentSection: View {
    @Binding var relativePath: String?
    let recordType: String
    let recordID: Int64?
    let onImageSelected: ((String?) -> Void)?
    @Environment(VisionProxyService.self) private var visionProxy
    @State private var isScanning = false
    @State private var scanError: String?

    init(
        relativePath: Binding<String?>,
        recordType: String,
        recordID: Int64? = nil,
        onImageSelected: ((String?) -> Void)? = nil
    ) {
        self._relativePath = relativePath
        self.recordType = recordType
        self.recordID = recordID
        self.onImageSelected = onImageSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Image")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                BooksImageThumbnail(relativePath: relativePath, size: 80)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("Choose File…") { chooseFile() }
                        Button("MaestroDAM…") { chooseFromDAM() }
                        Button("Photos Library…") { chooseFromPhotos() }
                    }
                    .controlSize(.small)

                    if relativePath != nil {
                        Button("Remove Image", role: .destructive) {
                            BooksImageStore.deleteImage(for: relativePath)
                            relativePath = nil
                            onImageSelected?(nil)
                        }
                        .controlSize(.small)
                    }

                    if recordType == "expense" || recordType == "bill" {
                        Button {
                            Task { await scanReceipt() }
                        } label: {
                            Label("Scan with Vision Proxy", systemImage: "text.viewfinder")
                        }
                        .controlSize(.small)
                        .disabled(relativePath == nil || isScanning)
                    }

                    if isScanning {
                        ProgressView("Reading receipt…")
                            .controlSize(.small)
                    }
                    if let scanError {
                        Text(scanError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chooseFile() {
        pickImage(startingAt: nil)
    }

    private func chooseFromDAM() {
        pickImage(startingAt: BooksImageStore.damSuggestedDirectory)
    }

    private func chooseFromPhotos() {
        let photosLibrary = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        pickImage(startingAt: photosLibrary)
    }

    private func pickImage(startingAt suggestedURL: URL?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .tiff, .gif, .heic, .heif]
        if let url = suggestedURL, FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            guard result == .OK, let url = panel.url else { return }
            if let path = BooksImageStore.copyImage(
                from: url, recordType: recordType, recordID: recordID) {
                relativePath = path
                onImageSelected?(path)
            }
        }
    }

    private func scanReceipt() async {
        guard let path = relativePath,
              let url = BooksImageStore.url(for: path),
              let data = try? Data(contentsOf: url) else {
            scanError = "Could not load image data."
            return
        }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            let prompt = """
                Extract the receipt details from this image and return a concise JSON object with keys: \
                merchant (string), date (YYYY-MM-DD or empty), total (number), tax (number or 0), \
                currency (3-letter code or empty), items (array of {description, amount}), category (string). \
                If a value is unclear, use null or an empty string. Return only the JSON object.
                """
            let caption = try await visionProxy.caption(imageData: data, prompt: prompt)
            onImageSelected?(relativePath)
            // Publish the raw OCR result back via a notification so the editor
            // can parse and apply values without complicating every caller.
            if let caption {
                NotificationCenter.default.post(
                    name: .booksReceiptScanned,
                    object: nil,
                    userInfo: ["ocrText": caption])
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let booksReceiptScanned = Notification.Name("booksReceiptScanned")
}
