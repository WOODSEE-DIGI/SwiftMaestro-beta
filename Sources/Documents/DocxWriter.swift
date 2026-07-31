import AppKit
import Foundation

// MARK: - Rich DOCX writer
//
// NSAttributedString → OOXML word/document.xml (+ rels, numbering, media),
// zipped via DocEngine.zipPackage. Round-trips the full TextKit editing
// model: text, bold/italic/underline/strikethrough, colors, highlights,
// fonts/sizes, paragraph alignment, indents, bulleted/numbered lists,
// hyperlinks, and inline images (text attachments → word/media).
//
// Element order inside <w:rPr> follows the ECMA-376 sequence
// (rFonts → b → i → strike → color → sz → highlight → u) — Word is
// strict about this.
enum DocxWriter {

    static func write(_ attributed: NSAttributedString, to url: URL) throws {
        var context = WriteContext()
        let body = try paragraphsXML(for: attributed, context: &context)

        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\(sectionProperties)</w:body></w:document>
            """

        var files: [String: Data] = [
            "[Content_Types].xml": Data(contentTypesXML.utf8),
            "_rels/.rels": Data(rootRelsXML.utf8),
            "word/document.xml": Data(documentXML.utf8),
            "word/_rels/document.xml.rels": Data(context.documentRelsXML().utf8),
        ]
        if context.hasLists {
            files["word/numbering.xml"] = Data(numberingXML.utf8)
        }
        for (name, data) in context.media {
            files["word/media/\(name)"] = data
        }

        try DocEngine.zipPackage(url: url, files: files)
    }

    // MARK: - Write context (rels + media collected during a pass)

    private struct WriteContext {
        var hyperlinks: [(id: String, url: URL)] = []
        var images: [(id: String, name: String)] = []
        var media: [(name: String, data: Data)] = []
        var hasLists = false
        private var nextRelID = 10
        private var nextImageIndex = 1

        mutating func addHyperlink(_ url: URL) -> String {
            defer { nextRelID += 1 }
            let id = "rId\(nextRelID)"
            hyperlinks.append((id, url))
            return id
        }

        mutating func addImage(data: Data, ext: String) -> (id: String, name: String) {
            defer { nextRelID += 1; nextImageIndex += 1 }
            let name = "image\(nextImageIndex).\(ext.isEmpty ? "png" : ext)"
            let id = "rId\(nextRelID)"
            media.append((name, data))
            images.append((id, name))
            return (id, name)
        }

        func documentRelsXML() -> String {
            var entries = hyperlinks.map {
                "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape($0.url.absoluteString))\" TargetMode=\"External\"/>"
            }
            entries += images.map {
                "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\($0.name)\"/>"
            }
            if hasLists {
                entries.append(
                    "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>")
            }
            return """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries.joined())</Relationships>
                """
        }
    }

    // MARK: - Paragraphs

    private static func paragraphsXML(
        for attributed: NSAttributedString, context: inout WriteContext
    ) throws -> String {
        let nsString = attributed.string as NSString
        var xml = ""
        var location = 0
        // Manual paragraph walk: the block-based enumerate APIs are escaping
        // closures and can't capture the inout write context.
        while location < nsString.length {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            xml += paragraphXML(for: attributed, range: paragraphRange, context: &context)
            location = NSMaxRange(paragraphRange)
        }
        // An entirely empty document still needs one paragraph.
        return xml.isEmpty ? "<w:p/>" : xml
    }

    private static func paragraphXML(
        for attributed: NSAttributedString, range: NSRange, context: inout WriteContext
    ) -> String {
        var properties = ""

        if let style = attributed.attribute(
            .paragraphStyle, at: range.location, effectiveRange: nil
        ) as? NSParagraphStyle {
            if !style.textLists.isEmpty {
                context.hasLists = true
                let numID = style.textLists[0].markerFormat == .decimal ? 2 : 1
                properties += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numID)\"/></w:numPr>"
            } else if style.headIndent > 0 || style.firstLineHeadIndent > 0 {
                let left = Int((style.headIndent * 20).rounded())
                let first = Int((style.firstLineHeadIndent * 20).rounded())
                properties += "<w:ind w:left=\"\(left)\" w:firstLine=\"\(max(0, first))\"/>"
            }
            switch style.alignment {
            case .center: properties += "<w:jc w:val=\"center\"/>"
            case .right: properties += "<w:jc w:val=\"right\"/>"
            case .justified: properties += "<w:jc w:val=\"both\"/>"
            default: break
            }
        }

        var runs = ""
        // Paragraph ranges include the trailing separator(s) — trim them so
        // they don't become stray empty runs.
        var contentRange = range
        while contentRange.length > 0 {
            let last = (attributed.string as NSString)
                .character(at: contentRange.location + contentRange.length - 1)
            if last == 0x0A || last == 0x0D { contentRange.length -= 1 } else { break }
        }
        if contentRange.length > 0 {
            // attributes(at:longestEffectiveRange:in:) gives merged attribute
            // runs without an escaping-closure capture of the context.
            var position = contentRange.location
            let end = NSMaxRange(contentRange)
            while position < end {
                var runRange = NSRange()
                let attributes = attributed.attributes(
                    at: position, longestEffectiveRange: &runRange, in: contentRange)
                runs += runXML(
                    text: (attributed.string as NSString).substring(with: runRange),
                    attributes: attributes, context: &context)
                position = NSMaxRange(runRange)
            }
        }

        let pPr = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(pPr)\(runs)</w:p>"
    }

    // MARK: - Runs

    private static func runXML(
        text: String, attributes: [NSAttributedString.Key: Any], context: inout WriteContext
    ) -> String {
        var rPr = ""

        // Font family, traits, size (sz is emitted later per schema order).
        var sizeHalfPoints: Int?
        if let font = attributes[.font] as? NSFont {
            let family = font.familyName ?? font.fontName
            rPr += "<w:rFonts w:ascii=\"\(escape(family))\" w:hAnsi=\"\(escape(family))\"/>"
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { rPr += "<w:b/>" }
            if traits.contains(.italicFontMask) { rPr += "<w:i/>" }
            sizeHalfPoints = Int((font.pointSize * 2).rounded())
        }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
            rPr += "<w:strike/>"
        }
        if let color = attributes[.foregroundColor] as? NSColor, let hex = hexString(color) {
            rPr += "<w:color w:val=\"\(hex)\"/>"
        }
        if let sizeHalfPoints {
            rPr += "<w:sz w:val=\"\(sizeHalfPoints)\"/>"
        }
        if let background = attributes[.backgroundColor] as? NSColor {
            rPr += "<w:highlight w:val=\"\(highlightName(background))\"/>"
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 {
            rPr += "<w:u w:val=\"single\"/>"
        }

        let rPrXML = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"

        // Attachments become inline drawings; text may contain form-feed
        // page breaks (our Insert→Page Break) split into break runs.
        if let attachment = attributes[.attachment] as? NSTextAttachment {
            if let drawing = drawingXML(for: attachment, context: &context) {
                return "<w:r>\(drawing)</w:r>"
            }
            return ""
        }

        let segments = text.components(separatedBy: "\u{0C}")
        var body = ""
        for (index, segment) in segments.enumerated() {
            if index > 0 { body += "<w:r><w:br w:type=\"page\"/></w:r>" }
            guard !segment.isEmpty else { continue }
            body += "<w:r>\(rPrXML)<w:t xml:space=\"preserve\">\(escape(segment))</w:t></w:r>"
        }

        if let url = attributes[.link] as? URL, !body.isEmpty {
            let relID = context.addHyperlink(url)
            return "<w:hyperlink r:id=\"\(relID)\">\(body)</w:hyperlink>"
        }
        return body
    }

    // MARK: - Images

    private static func drawingXML(
        for attachment: NSTextAttachment, context: inout WriteContext
    ) -> String? {
        guard let data = attachment.fileWrapper?.regularFileContents else { return nil }
        let ext = attachment.fileWrapper?.preferredFilename?
            .components(separatedBy: ".").last ?? "png"
        let rel = context.addImage(data: data, ext: ext)
        let size = NSImage(data: data)?.size ?? NSSize(width: 200, height: 200)
        let cx = Int((size.width * 9525).rounded())   // px → EMU (96dpi)
        let cy = Int((size.height * 9525).rounded())
        return """
            <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(rel.name.hashValue & 0x7FFFFFFF)" name="\(rel.name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="\(rel.name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rel.id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """
    }

    // MARK: - Color helpers

    static func hexString(_ color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()))
    }

    /// OOXML highlight takes NAMED colors only — snap to the nearest of the
    /// six Word presets (default yellow for unmapped tones).
    static func highlightName(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "yellow" }
        let presets: [(name: String, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            ("yellow", 1, 1, 0), ("green", 0, 1, 0), ("cyan", 0, 1, 1),
            ("magenta", 1, 0, 1), ("red", 1, 0, 0), ("blue", 0, 0, 1),
        ]
        var best = "yellow"
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for preset in presets {
            let distance = abs(srgb.redComponent - preset.r)
                + abs(srgb.greenComponent - preset.g)
                + abs(srgb.blueComponent - preset.b)
            if distance < bestDistance {
                bestDistance = distance
                best = preset.name
            }
        }
        return best
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Static package parts

    private static let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>
        """

    private static let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """

    /// Bullet (disc → numId 1) and decimal (→ numId 2) list definitions.
    private static let numberingXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val=""/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>
        """

    /// A4 with 50pt (1000-twip) margins, matching the app's paper look.
    private static let sectionProperties = """
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1000" w:right="1000" w:bottom="1000" w:left="1000" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
        """
}
