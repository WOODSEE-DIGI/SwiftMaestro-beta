import Foundation
import GRDB

// MARK: - Email import settings

/// Persistent settings for the Books email-import pipeline.
struct BooksEmailImportSettings: Codable, Equatable {
    var isEnabled: Bool = false
    /// Folder where .eml / .emlx files are dropped by Apple Mail rules or
    /// external forwarding services that can write to the local filesystem.
    var importFolderURL: String?
    /// Archive processed messages so they are not re-imported.
    var archiveProcessed: Bool = true
    /// Seconds between folder scans when the app is in the foreground.
    var scanInterval: Int = 300

    static var `default`: BooksEmailImportSettings {
        BooksEmailImportSettings()
    }

    static func load() -> BooksEmailImportSettings {
        guard let data = UserDefaults.standard.data(forKey: "maestrobooks.emailImport.settings"),
              let settings = try? JSONDecoder().decode(BooksEmailImportSettings.self, from: data) else {
            return BooksEmailImportSettings(
                importFolderURL: BooksEmailImportService.defaultImportFolder.path)
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "maestrobooks.emailImport.settings")
        }
    }

    var resolvedImportFolder: URL {
        if let path = importFolderURL, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return BooksEmailImportService.defaultImportFolder
    }
}

// MARK: - Imported email model

/// A receipt or bill extracted from an email and its attachments.
struct BooksImportedEmail: Identifiable, Sendable {
    let id = UUID()
    let sourceFile: URL
    let subject: String
    let sender: String
    let date: Date?
    let body: String
    let attachments: [BooksEmailAttachment]
}

struct BooksEmailAttachment: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
    let imagePath: String?
}

// MARK: - Email import service

/// Watches a folder for .eml / .emlx files, parses them, runs attachments
/// through Vision Proxy OCR, and creates expenses/bills in MaestroBooks.
@Observable
@MainActor
final class BooksEmailImportService {
    static let shared = BooksEmailImportService()

    nonisolated static var defaultImportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftMaestro/Books/EmailImports", isDirectory: true)
    }

    private var timer: Timer?
    private var isScanning = false
    private(set) var lastResult: String?

    var settings: BooksEmailImportSettings {
        didSet { settings.save() }
    }

    private init() {
        self.settings = BooksEmailImportSettings.load()
    }

    func startMonitoring() {
        stopMonitoring()
        guard settings.isEnabled else { return }
        let interval = max(30, Double(settings.scanInterval))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scanOnce()
            }
        }
        Task { @MainActor in
            await scanOnce()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Manually trigger one scan. Returns the number of imported records.
    @discardableResult
    func scanOnce() async -> Int {
        guard !isScanning else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let folder = settings.resolvedImportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "eml" || $0.pathExtension.lowercased() == "emlx" }
            .sorted { $0.path < $1.path } ?? []

        guard !files.isEmpty else { return 0 }

        var imported = 0
        for file in files {
            do {
                if let importedEmail = try await parse(file: file) {
                    let count = try await process(importedEmail)
                    imported += count
                    if settings.archiveProcessed {
                        archive(file: file)
                    } else {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                lastResult = "Failed to import \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if imported > 0 {
            lastResult = "Imported \(imported) record(s) from email."
            // Trigger a view-model reload via notification so any open
            // MaestroBooks panel refreshes expenses/bills.
            NotificationCenter.default.post(name: .booksEmailImportCompleted, object: nil)
        }
        return imported
    }

    /// Parse an .eml or .emlx file into an imported email model.
    private func parse(file: URL) async throws -> BooksImportedEmail? {
        let raw: String
        let ext = file.pathExtension.lowercased()
        if ext == "emlx" {
            raw = try readEMLX(at: file)
        } else {
            raw = try String(contentsOf: file, encoding: .utf8)
        }

        let entity = try MIMEEntity.parse(raw)
        let headers = entity.headersDictionary()

        let subject = MailBodyStore.decodeRFC2047(headers["subject"]?.first ?? "")
        let sender = MailBodyStore.decodeRFC2047(headers["from"]?.first ?? "")
        let date = parseDate(headers["date"]?.first)
        let body = extractBodyText(from: entity)
        let attachments = extractAttachments(from: entity)

        return BooksImportedEmail(
            sourceFile: file,
            subject: subject,
            sender: sender,
            date: date,
            body: body,
            attachments: attachments)
    }

    private func readEMLX(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let firstNewline = data.firstIndex(of: 0x0A) else {
            throw BooksEmailImportError.unreadable
        }
        let prefix = data[data.startIndex..<firstNewline]
        guard let byteCount = Int(String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              byteCount > 0 else {
            throw BooksEmailImportError.unreadable
        }
        let messageStart = firstNewline + 1
        let messageEnd = min(messageStart + byteCount, data.endIndex)
        let messageData = data[messageStart..<messageEnd]
        return String(decoding: messageData, as: UTF8.self)
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private func extractBodyText(from entity: MIMEEntity) -> String {
        if let plain = firstPart(of: entity, contentType: "text/plain") {
            return plain.decodedTextBody()
        }
        if let html = firstPart(of: entity, contentType: "text/html") {
            return html.decodedTextBody().strippingHTMLTags()
        }
        if !entity.isMultipart {
            return entity.decodedTextBody()
        }
        return ""
    }

    private func firstPart(of entity: MIMEEntity, contentType: String) -> MIMEEntity? {
        if !entity.isMultipart {
            let type = (entity.headerValue("Content-Type") ?? "text/plain").lowercased()
            return type.contains(contentType) ? entity : nil
        }
        for child in entity.children {
            if let found = firstPart(of: child, contentType: contentType) {
                return found
            }
        }
        return nil
    }

    private func extractAttachments(from entity: MIMEEntity) -> [BooksEmailAttachment] {
        var results: [BooksEmailAttachment] = []
        collectAttachments(from: entity, into: &results)
        return results
    }

    private func collectAttachments(from entity: MIMEEntity, into results: inout [BooksEmailAttachment]) {
        if entity.isMultipart {
            for child in entity.children {
                collectAttachments(from: child, into: &results)
            }
            return
        }
        let disposition = (entity.headerValue("Content-Disposition") ?? "").lowercased()
        let contentType = (entity.headerValue("Content-Type") ?? "application/octet-stream").lowercased()
        let isAttachment = disposition.contains("attachment")
            || (disposition.contains("filename") && !contentType.contains("text/"))
            || (!contentType.contains("text/") && !contentType.contains("multipart/"))

        guard isAttachment else { return }

        let rawBody = entity.body
        let transferEncoding = (entity.headerValue("Content-Transfer-Encoding") ?? "").lowercased()
        let data: Data
        if transferEncoding.contains("base64") {
            let compact = rawBody
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) ?? Data(rawBody.utf8)
        } else if transferEncoding.contains("quoted-printable") {
            data = MIMEEntity.decodeQuotedPrintable(rawBody).data(using: .utf8) ?? Data()
        } else {
            data = Data(rawBody.utf8)
        }

        let filename = parseFilename(from: entity) ?? "attachment"
        let imagePath = contentType.hasPrefix("image/") || filename.isImageExtension
            ? BooksImageStore.copyImage(fromTemporaryData: data, filename: filename, recordType: "expense")
            : nil

        results.append(BooksEmailAttachment(
            filename: filename,
            mimeType: contentType,
            data: data,
            imagePath: imagePath))
    }

    private func parseFilename(from entity: MIMEEntity) -> String? {
        let disposition = entity.headerValue("Content-Disposition") ?? ""
        if let range = disposition.range(of: "filename=", options: [.caseInsensitive]) {
            var value = String(disposition[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value.removeFirst()
                if let end = value.firstIndex(of: "\"") {
                    return String(value[..<end])
                }
            } else {
                return value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func archive(file: URL) {
        let archiveDir = file.deletingLastPathComponent().appendingPathComponent("processed", isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let dest = archiveDir.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.moveItem(at: file, to: dest)
    }

    // MARK: - Record creation

    /// Creates expenses/bills from the email. Returns the number of records.
    private func process(_ email: BooksImportedEmail) async throws -> Int {
        let visionProxy = VisionProxyService()
        guard visionProxy.config.isEnabled else {
            throw BooksEmailImportError.visionProxyUnavailable
        }

        var created = 0
        let seller = BooksSeller.load()

        for attachment in email.attachments {
            guard attachment.imagePath != nil || attachment.filename.isPDFExtension else { continue }

            let ocrText: String?
            if let path = attachment.imagePath,
               let url = BooksImageStore.url(for: path),
               let data = try? Data(contentsOf: url) {
                ocrText = try? await visionProxy.caption(
                    imageData: data,
                    prompt: BooksEmailImportService.receiptPrompt)
            } else if attachment.filename.isPDFExtension {
                // PDF OCR is not implemented here; store the attachment data
                // as notes and let the user finish the record manually.
                ocrText = "PDF attachment: \(attachment.filename)"
            } else {
                ocrText = nil
            }

            var expense = BooksExpense(
                id: nil,
                supplier: guessSupplier(from: email, ocr: ocrText),
                expenseDescription: guessDescription(from: email, ocr: ocrText),
                reference: nil,
                accountCode: seller.defaultExpenseAccountCode,
                issueDate: email.date ?? Date(),
                statusRaw: BooksInvoiceStatus.draft.rawValue,
                currency: seller.currency,
                taxRate: seller.taxRate,
                taxType: seller.expenseTaxType,
                subtotal: guessAmount(from: ocrText),
                notes: composeNotes(from: email, ocr: ocrText, attachment: attachment),
                imageURL: attachment.imagePath,
                xeroID: nil,
                createdAt: Date(),
                updatedAt: Date())

            _ = try BooksDatabase.shared.saveExpense(&expense)
            created += 1
        }

        // If there were no usable attachments, create a skeleton expense from
        // the email body so nothing is lost.
        if created == 0 {
            var expense = BooksExpense(
                id: nil,
                supplier: guessSupplier(from: email, ocr: nil),
                expenseDescription: email.subject.isEmpty ? "Email import" : email.subject,
                reference: nil,
                accountCode: seller.defaultExpenseAccountCode,
                issueDate: email.date ?? Date(),
                statusRaw: BooksInvoiceStatus.draft.rawValue,
                currency: seller.currency,
                taxRate: seller.taxRate,
                taxType: seller.expenseTaxType,
                subtotal: 0,
                notes: composeNotes(from: email, ocr: nil, attachment: nil),
                imageURL: nil,
                xeroID: nil,
                createdAt: Date(),
                updatedAt: Date())
            _ = try BooksDatabase.shared.saveExpense(&expense)
            created = 1
        }

        return created
    }

    private func guessSupplier(from email: BooksImportedEmail, ocr: String?) -> String {
        if let merchant = extractJSONField(named: "merchant", from: ocr), !merchant.isEmpty {
            return merchant
        }
        let from = email.sender
        if let emailAddr = from.components(separatedBy: CharacterSet(charactersIn: "<>"))
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.contains("@") }) {
            return emailAddr
        }
        return from.isEmpty ? "Unknown sender" : from
    }

    private func guessDescription(from email: BooksImportedEmail, ocr: String?) -> String {
        if let category = extractJSONField(named: "category", from: ocr), !category.isEmpty {
            return category
        }
        if !email.subject.isEmpty { return email.subject }
        return "Expense from email"
    }

    private func guessAmount(from ocr: String?) -> Double {
        guard let ocr else { return 0 }
        if let total = extractJSONField(named: "total", from: ocr),
           let value = Double(total) {
            return value
        }
        return 0
    }

    private func composeNotes(from email: BooksImportedEmail, ocr: String?, attachment: BooksEmailAttachment?) -> String {
        var parts: [String] = []
        parts.append("Imported from email: \(email.sourceFile.lastPathComponent)")
        if !email.sender.isEmpty { parts.append("From: \(email.sender)") }
        if !email.subject.isEmpty { parts.append("Subject: \(email.subject)") }
        if let attachment { parts.append("Attachment: \(attachment.filename)") }
        if let ocr, !ocr.isEmpty {
            parts.append("--- OCR ---")
            parts.append(ocr)
        }
        return parts.joined(separator: "\n")
    }

    private func extractJSONField(named key: String, from text: String?) -> String? {
        guard let text else { return nil }
        // Best-effort: look for "key": "value" or "key": number
        let patterns = [
            "\"\(key)\"\\s*:\\s*\"([^\"]*)\"",
            "\"\(key)\"\\s*:\\s*([0-9]+\\.?[0-9]*)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let valueRange = Range(match.range(at: 1), in: text) {
                return String(text[valueRange])
            }
        }
        return nil
    }

    // MARK: - Constants

    static let receiptPrompt = """
        Extract the receipt details from this image and return a concise JSON object with keys: \
        merchant (string), date (YYYY-MM-DD or empty), total (number), tax (number or 0), \
        currency (3-letter code or empty), items (array of {description, amount}), category (string). \
        If a value is unclear, use null or an empty string. Return only the JSON object.
        """
}

// MARK: - Helpers

enum BooksEmailImportError: Error, LocalizedError {
    case unreadable
    case visionProxyUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Could not read the email file."
        case .visionProxyUnavailable: return "Vision Proxy is not available. Enable it in Settings → Vision Proxy."
        }
    }
}

extension Notification.Name {
    static let booksEmailImportCompleted = Notification.Name("booksEmailImportCompleted")
}

private extension String {
    func strippingHTMLTags() -> String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return self
        }
        return attributed.string
    }

    var isImageExtension: Bool {
        let ext = self.lowercased()
        return ["jpg", "jpeg", "png", "tiff", "tif", "gif", "heic", "heif", "webp"].contains(ext)
    }

    var isPDFExtension: Bool {
        self.lowercased() == "pdf"
    }
}

