import Foundation
import PDFKit

/// Shared text/binary extraction for files. Used by read_file and by the
/// document chunking / RAG pipeline so both paths behave consistently.
enum FileContentExtractor {

    enum FileCategory {
        case text
        case document
        case pdf
        case image
        case binary
    }

    static let textFileExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "json", "xml", "yaml", "yml", "csv",
        "tsv", "log", "sh", "bash", "zsh", "py", "js", "ts", "jsx", "tsx",
        "html", "htm", "css", "scss", "sass", "less", "c", "cpp", "cc", "h",
        "hpp", "m", "mm", "java", "kt", "go", "rs", "rb", "php", "pl", "pm",
        "sql", "gitignore", "entitlements", "plist", "properties", "ini", "conf",
        "cfg", "config", "toml", "lock", "map", "svg"
    ]

    static let documentFileExtensions: Set<String> = [
        "docx", "doc", "rtf", "odt", "pages"
    ]

    static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp", "webp", "gif",
        "raw", "dng", "cr2", "nef", "arw", "orf", "raf"
    ]

    static func category(for path: String) -> FileCategory {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if textFileExtensions.contains(ext) { return .text }
        if documentFileExtensions.contains(ext) { return .document }
        if imageFileExtensions.contains(ext) { return .image }
        return .binary
    }

    static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let common: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff",
            "bmp": "image/bmp", "webp": "image/webp", "gif": "image/gif",
            "svg": "image/svg+xml",
            "pdf": "application/pdf",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "doc": "application/msword", "rtf": "application/rtf",
            "odt": "application/vnd.oasis.opendocument.text",
            "pages": "application/vnd.apple.pages",
            "zip": "application/zip", "tar": "application/x-tar",
            "gz": "application/gzip", "bz2": "application/x-bzip2",
            "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
            "mp3": "audio/mpeg", "mp4": "video/mp4", "mov": "video/quicktime",
            "wav": "audio/wav", "aiff": "audio/aiff", "ogg": "audio/ogg",
            "dmg": "application/x-apple-diskimage",
            "pkg": "application/vnd.apple.installer+xml",
            "app": "application/x-mach-binary", "dylib": "application/x-mach-binary",
            "so": "application/x-sharedlib", "bin": "application/octet-stream",
            "exe": "application/x-msdownload", "dll": "application/x-msdownload"
        ]
        return common[ext] ?? "application/octet-stream"
    }

    /// Extract plain text from a file if possible. Returns nil for true binary files
    /// or unsupported document types.
    static func extractText(from path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = (path as NSString).pathExtension.lowercased()
        let cat = category(for: path)

        switch cat {
        case .text:
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .macOSRoman)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .ascii)

        case .pdf:
            return extractPDFText(at: url)

        case .document:
            return extractDocumentText(at: url, ext: ext)

        case .image, .binary:
            return nil
        }
    }

    static func extractDocumentText(at url: URL, ext: String) -> String? {
        let documentType: NSAttributedString.DocumentType?
        switch ext {
        case "docx":
            documentType = .officeOpenXML
        case "rtf":
            documentType = .rtf
        case "odt":
            documentType = .openDocument
        case "html", "htm":
            documentType = .html
        default:
            documentType = nil
        }

        if let documentType = documentType {
            if let attributedString = try? NSAttributedString(
                url: url,
                options: [.documentType: documentType],
                documentAttributes: nil
            ), !attributedString.string.isEmpty {
                return attributedString.string
            }
        }

        // Fallback: let the system infer the document type.
        if let attributedString = try? NSAttributedString(
            url: url,
            options: [:],
            documentAttributes: nil
        ), !attributedString.string.isEmpty {
            return attributedString.string
        }
        return nil
    }

    static func extractPDFText(at url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            parts.append(page.string ?? "")
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
