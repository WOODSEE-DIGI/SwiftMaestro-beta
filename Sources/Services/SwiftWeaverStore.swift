import Foundation
import SwiftUI

// MARK: - SwiftWeaver Store
//
// State for SwiftWeaver, the Dreamweaver-style HTML editor panel.
// Clean-room replacement for OverlayBuilderStore: editor concerns only.

/// Starter document for a new SwiftWeaver file.
enum SwiftWeaverDefaults {
    static let html = """
    <div class="overlay">
      <div class="accent-bar"></div>
      <div class="content">
        <div class="title">Your Title Here</div>
        <div class="subtitle">Subtitle text goes here</div>
      </div>
    </div>
    """

    static let css = """
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
      background: transparent;
      width: 1920px;
      height: 1080px;
      overflow: hidden;
    }

    .overlay {
      position: absolute;
      left: 60px;
      bottom: 80px;
      display: flex;
      flex-direction: row;
      align-items: stretch;
      gap: 0;
    }

    .accent-bar {
      width: 5px;
      background: #7c3aed;
      border-radius: 3px 0 0 3px;
    }

    .content {
      background: rgba(12, 12, 18, 0.92);
      border: 1px solid rgba(124, 58, 237, 0.3);
      border-left: none;
      border-radius: 0 10px 10px 0;
      padding: 18px 28px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .title {
      color: #ffffff;
      font-size: 34px;
      font-weight: 600;
      letter-spacing: -0.3px;
    }

    .subtitle {
      color: rgba(255, 255, 255, 0.7);
      font-size: 16px;
      font-weight: 400;
    }
    """
}

@Observable
@MainActor
final class SwiftWeaverStore {
    static let shared = SwiftWeaverStore()

    // MARK: Document

    var htmlSource: String = SwiftWeaverDefaults.html
    var cssSource: String = SwiftWeaverDefaults.css
    var fileURL: URL? = nil

    // MARK: Preview

    var fluidPreview: Bool = true
    var canvasWidth: Int = 1920
    var canvasHeight: Int = 1080
    var previewScale: Double = 1.0

    // MARK: Direct-manipulation edit state

    var fontEditSelector: String? = nil
    var fontEditInfo: String = ""

    // MARK: Templates

    func applyWebsiteTemplate(_ template: WebsiteTemplate) {
        htmlSource = template.html
        cssSource = template.css
        if let w = template.canvasWidth, let h = template.canvasHeight {
            canvasWidth = w
            canvasHeight = h
            fluidPreview = false
        } else {
            fluidPreview = true
        }
        fileURL = nil
    }

    // MARK: File Operations

    func newDocument() {
        htmlSource = SwiftWeaverDefaults.html
        cssSource = SwiftWeaverDefaults.css
        fileURL = nil
        fluidPreview = true
    }

    func openDocument(from url: URL) throws {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var css = ""
        var html = raw
        if let styleRange = raw.range(of: #"<style[^>]*>(.*?)</style>"#,
                                      options: [.regularExpression, .caseInsensitive]) {
            var block = String(raw[styleRange])
            if let openEnd = block.range(of: ">", options: .regularExpression) {
                block = String(block[openEnd.upperBound...])
            }
            if let closeStart = block.range(of: "</style>", options: .caseInsensitive) {
                block = String(block[..<closeStart.lowerBound])
            }
            css = block.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bodyRange = raw.range(of: #"<body[^>]*>(.*?)</body>"#,
                                     options: [.regularExpression, .caseInsensitive]) {
            var body = String(raw[bodyRange])
            if let openEnd = body.range(of: ">", options: .regularExpression) {
                body = String(body[openEnd.upperBound...])
            }
            if let closeStart = body.range(of: "</body>", options: .caseInsensitive) {
                body = String(body[..<closeStart.lowerBound])
            }
            html = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        htmlSource = html
        cssSource = css
        fileURL = url
        fluidPreview = true
    }

    var documentHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(cssSource)
        </style>
        </head>
        <body>
        \(htmlSource)
        </body>
        </html>
        """
    }

    func saveDocument(to url: URL) throws {
        try documentHTML.write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
    }
}

// MARK: - Color hex helpers (used by the font panel + CSS variables panel)

extension Color {
    /// Parse a 6-digit `#RRGGBB` hex string.
    init(hex6: String) {
        var hex = hex6.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hex.count == 6 { hex = hex + "ff" }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        (r, g, b, a) = (int >> 24 & 0xFF, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components else { return "#000000" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
