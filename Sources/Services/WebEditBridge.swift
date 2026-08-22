import Foundation

// MARK: - Web Edit Bridge
//
// Direct-manipulation layer for the HTML editor's WKWebView preview:
//   - Shift+drag an element to move it (writes left/top back into CSS)
//   - Right-click an element to open font editing (size/weight/color/align)
// Edits are written into the CSS source by selector rule, so the code view
// shows the change live (educational) and the result persists with Save.

/// Mutates CSS source text by selector: updates the property inside an
/// existing rule, or appends a new rule at the end. String surgery only.
enum CSSRuleUpdater {

    static func setProperty(in source: String, selector: String,
                            property: String, value: String) -> String {
        guard let selRange = source.range(of: selector),
              let braceRange = source.range(of: "{", range: selRange.upperBound..<source.endIndex),
              let closeRange = source.range(of: "}", range: braceRange.upperBound..<source.endIndex)
        else {
            return source + "\n\n\(selector) {\n  \(property): \(value);\n}\n"
        }

        let bodyStart = braceRange.upperBound
        let body = source[bodyStart..<closeRange.lowerBound]
        let propPattern = NSRegularExpression.escapedPattern(for: property) + #"\s*:[^;]+;"#

        if let propRange = body.range(of: propPattern, options: .regularExpression) {
            let start = source.index(bodyStart, offsetBy: body.distance(from: body.startIndex, to: propRange.lowerBound))
            let end = source.index(start, offsetBy: body[propRange].count)
            var out = source
            out.replaceSubrange(start..<end, with: "\(property): \(value);")
            return out
        }

        var out = source
        out.insert(contentsOf: "\n  \(property): \(value);", at: closeRange.lowerBound)
        return out
    }

    /// Reads a property's current value from a selector's rule, if present.
    static func getProperty(in source: String, selector: String, property: String) -> String? {
        guard let selRange = source.range(of: selector),
              let braceRange = source.range(of: "{", range: selRange.upperBound..<source.endIndex),
              let closeRange = source.range(of: "}", range: braceRange.upperBound..<source.endIndex)
        else { return nil }
        let body = String(source[braceRange.upperBound..<closeRange.lowerBound])
        let pattern = NSRegularExpression.escapedPattern(for: property) + #"\s*:\s*([^;]+);"#
        guard let match = body.range(of: pattern, options: .regularExpression) else { return nil }
        var value = String(body[match])
        if let colon = value.firstIndex(of: ":") { value = String(value[value.index(after: colon)...]) }
        return value.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - JS Bridge Source

/// Injected into every preview document. Shift+drag moves elements;
/// right-click requests the font editor. Deltas arrive in SCREEN points —
/// the store divides by its previewScale to recover canvas pixels.
enum WebEditBridgeJS {
    static let source = """
    (function() {
      let dragEl = null, startX = 0, startY = 0;
      function selectorFor(el) {
        if (el.id) return '#' + el.id;
        if (el.classList && el.classList.length) return '.' + el.classList[0];
        return el.tagName.toLowerCase();
      }
      document.addEventListener('mousedown', function(e) {
        if (!e.shiftKey) return;
        e.preventDefault();
        dragEl = e.target;
        startX = e.clientX; startY = e.clientY;
        dragEl.style.outline = '2px dashed #e900f9';
      }, true);
      document.addEventListener('mousemove', function(e) {
        if (!dragEl) return;
        dragEl.style.transform = 'translate(' + (e.clientX - startX) + 'px,' + (e.clientY - startY) + 'px)';
      }, true);
      document.addEventListener('mouseup', function(e) {
        if (!dragEl) return;
        let el = dragEl; dragEl = null;
        el.style.outline = ''; el.style.transform = '';
        window.webkit.messageHandlers.webEdit.postMessage({
          type: 'move', selector: selectorFor(el),
          dx: e.clientX - startX, dy: e.clientY - startY,
          position: getComputedStyle(el).position
        });
      }, true);
      document.addEventListener('contextmenu', function(e) {
        e.preventDefault();
        let el = e.target;
        let cs = getComputedStyle(el);
        window.webkit.messageHandlers.webEdit.postMessage({
          type: 'font', selector: selectorFor(el),
          text: (el.textContent || '').trim().slice(0, 40),
          fontSize: cs.fontSize, fontWeight: cs.fontWeight, color: cs.color
        });
      }, true);
    })();
    """
}

// MARK: - Store integration

extension SwiftWeaverStore {

    /// Applies a shift+drag move: converts screen deltas to canvas pixels
    /// and writes left/top (plus position: relative when the element was
    /// static) into the element's CSS rule. The source change reloads the
    /// preview with the element at its new home.
    func applyWebMove(selector: String, dx: Double, dy: Double, position: String) {
        let scale = previewScale > 0 ? previewScale : 1.0
        let canvasDX = Int((dx / scale).rounded())
        let canvasDY = Int((dy / scale).rounded())
        guard canvasDX != 0 || canvasDY != 0 else { return }

        let curLeft = CSSRuleUpdater.getProperty(in: cssSource, selector: selector, property: "left")
            .flatMap { Int($0.replacingOccurrences(of: "px", with: "")) } ?? 0
        let curTop = CSSRuleUpdater.getProperty(in: cssSource, selector: selector, property: "top")
            .flatMap { Int($0.replacingOccurrences(of: "px", with: "")) } ?? 0

        var css = cssSource
        if position == "static" || CSSRuleUpdater.getProperty(in: css, selector: selector, property: "position") == nil {
            css = CSSRuleUpdater.setProperty(in: css, selector: selector, property: "position", value: "relative")
        }
        css = CSSRuleUpdater.setProperty(in: css, selector: selector, property: "left", value: "\(curLeft + canvasDX)px")
        css = CSSRuleUpdater.setProperty(in: css, selector: selector, property: "top", value: "\(curTop + canvasDY)px")
        cssSource = css
    }

    /// Applies a font property edit from the right-click font panel.
    func applyFontEdit(property: String, value: String) {
        guard let selector = fontEditSelector else { return }
        cssSource = CSSRuleUpdater.setProperty(
            in: cssSource, selector: selector, property: property, value: value)
    }
}
