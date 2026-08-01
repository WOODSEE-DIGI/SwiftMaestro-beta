import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Document tools (MaestroDocs engine)
//
// Agent-first document access: read text out of office/PDF documents into
// context, and author new documents as outputs. Powered by the native
// `DocEngine` (no external dependencies — PDFKit/TextKit/ZIP+XML/CoreText).
//
// Writes follow the same safeguards as write_file: the Context-tab
// authorized-folders allowlist is enforced, and any overwrite is preceded
// by a ChangeGuard rollback snapshot (fail closed).
extension MaestroTools {

    static func registerDocumentTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "document_read", spec: documentToolSpecs[0],
                category: ToolCategory.documents.rawValue,
                handler: { call in await documentRead(call) }),
            ToolDefinition(
                name: "document_create", spec: documentToolSpecs[1],
                category: ToolCategory.documents.rawValue,
                handler: { call in await documentCreate(call) }),
            ToolDefinition(
                name: "document_info", spec: documentToolSpecs[2],
                category: ToolCategory.documents.rawValue,
                handler: { call in await documentInfo(call) }),
        ])
    }

    static var documentToolSpecs: [ToolSpec] {
        [
            rawSpec(
                "document_read",
                "Read a document's text content into context. Supports PDF, Word (doc/docx), "
                    + "RTF, OpenDocument text (odt), plain text/Markdown, HTML, CSV/TSV, Excel "
                    + "(xlsx — sheets returned as markdown tables), PowerPoint (pptx — per-slide "
                    + "text), EPUB ebooks, and iWork (Pages/Numbers/Keynote via the embedded "
                    + "preview PDF). Use this to summarize, quote, or analyze documents.",
                properties: [
                    "path": ["type": "string"],
                    "max_chars": ["type": "integer"],
                ],
                required: ["path"]),
            rawSpec(
                "document_create",
                "Create a document file from text content. Format is inferred from the file "
                    + "extension: txt, md, csv, tsv, rtf, pdf, docx, xlsx, odt. For xlsx/csv/tsv "
                    + "provide rows as comma- or tab-separated lines, or a markdown table. For "
                    + "pdf/docx/odt/rtf provide plain text; blank lines separate paragraphs. "
                    + "Overwrites are snapshotted for rollback (ChangeGuard).",
                properties: [
                    "path": ["type": "string"],
                    "content": ["type": "string"],
                    "title": ["type": "string"],
                ],
                required: ["path", "content"]),
            rawSpec(
                "document_info",
                "Get facts about a document without loading its content: format, byte size, "
                    + "word count, page count (PDF/PPTX/EPUB), and sheet names (XLSX).",
                properties: [
                    "path": ["type": "string"],
                ],
                required: ["path"]),
        ]
    }

    // MARK: - Args

    private struct DocumentReadArgs: Codable {
        let path: String?
        let max_chars: Int?
    }

    private struct DocumentCreateArgs: Codable {
        let path: String?
        let content: String?
        let title: String?
    }

    private struct DocumentInfoArgs: Codable {
        let path: String?
    }

    // MARK: - document_read

    static func documentRead(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DocumentReadArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("document_read requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("document_read requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let url = URL(fileURLWithPath: resolved)
        guard FileManager.default.fileExists(atPath: resolved) else {
            return errorJSON("no such file: '\(resolved)'")
        }

        do {
            let content = try DocEngine.read(url)
            var text = content.text
            if let cap = args.max_chars, cap > 0, text.count > cap {
                text = String(text.prefix(cap)) + "\n…[truncated to \(cap) chars]"
            }
            var result: [String: Any] = [
                "status": "ok",
                "format": content.format,
                "truncated": content.truncated,
                "text": text,
            ]
            if let pages = content.pageCount { result["pages"] = pages }
            if let sheets = content.sheetNames { result["sheets"] = sheets.joined(separator: ", ") }
            return jsonString(result)
        } catch {
            return errorJSON("document_read failed for '\(resolved)': \(error)")
        }
    }

    // MARK: - document_create

    static func documentCreate(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DocumentCreateArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let content = args.content else {
            return errorJSON("document_create requires 'path' and 'content'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("document_create requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }

        // Data safeguard: preserve existing bytes before mutating. Fail
        // closed — an unsnapshotable change is an unrollbackable change.
        if FileManager.default.fileExists(atPath: resolved) {
            do {
                try ChangeGuard.shared.snapshotForMutation(
                    path: resolved, kind: .overwrite, tool: "document_create")
            } catch {
                return errorJSON(
                    "create blocked: could not create a rollback snapshot for '\(resolved)' "
                    + "(\(error.localizedDescription)). Data safeguards require every change to be reversible.")
            }
        }

        do {
            let bytes = try DocEngine.create(
                URL(fileURLWithPath: resolved), content: content, title: args.title)
            return jsonString([
                "status": "created",
                "path": resolved,
                "bytes": "\(bytes)",
                "format": (resolved as NSString).pathExtension.lowercased(),
            ])
        } catch {
            return errorJSON("document_create failed for '\(resolved)': \(error)")
        }
    }

    // MARK: - document_info

    static func documentInfo(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DocumentInfoArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("document_info requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("document_info requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        guard FileManager.default.fileExists(atPath: resolved) else {
            return errorJSON("no such file: '\(resolved)'")
        }

        var info = (try? DocEngine.info(URL(fileURLWithPath: resolved))) ?? [:]
        info["status"] = "ok"
        info["path"] = resolved
        return jsonString(info)
    }
}
