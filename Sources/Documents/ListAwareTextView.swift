import AppKit

// MARK: - List-aware text view
//
// NSTextView with word-processor list behavior for paragraphs whose
// paragraph style carries textLists (see applyList in MaestroDocsViewModel):
//
//   • Return inside a list item continues the list on the new paragraph
//     (typing attributes normally inherit the style, but we set them
//     explicitly so continuation can't regress).
//   • Return on an EMPTY list item exits the list: the bullet is removed
//     and the paragraph becomes body text — no extra empty bullet.
//   • Backspace at the very start of a list item removes the bullet first
//     (text untouched); a second Backspace merges paragraphs as usual.
final class ListAwareTextView: NSTextView {

    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, !string.isEmpty else {
            super.insertNewline(sender)
            return
        }
        let paragraphRange = (string as NSString).paragraphRange(for: selectedRange())
        // Caret at the very end of a document trailing with newline(s) can
        // produce an EMPTY paragraph range whose location == storage length —
        // attribute lookups there throw. Clamp the lookup.
        let safeLocation = min(paragraphRange.location, max(0, storage.length - 1))
        guard let style = storage.attribute(
            .paragraphStyle, at: safeLocation, effectiveRange: nil
        ) as? NSParagraphStyle, !style.textLists.isEmpty else {
            super.insertNewline(sender)
            return
        }

        let content = (string as NSString).substring(with: paragraphRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty {
            if paragraphRange.length > 0 {
                stripList(from: paragraphRange, basedOn: style)
            } else {
                // Nothing to strip at an empty trailing range — just make
                // continued typing body text.
                typingAttributes[.paragraphStyle] = plainStyle(from: style)
            }
            return   // the emptied bullet becomes the body line — no newline
        }

        // Continue: guarantee the new paragraph inherits the list style.
        typingAttributes[.paragraphStyle] = style
        super.insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage, !string.isEmpty, selectedRange().length == 0 else {
            super.deleteBackward(sender)
            return
        }
        let location = selectedRange().location
        guard location > 0, location < storage.length else {
            super.deleteBackward(sender)
            return
        }
        let paragraphRange = (string as NSString)
            .paragraphRange(for: NSRange(location: location, length: 0))
        guard paragraphRange.location == location,   // caret at paragraph start
              let style = storage.attribute(
                .paragraphStyle, at: location, effectiveRange: nil
              ) as? NSParagraphStyle,
              !style.textLists.isEmpty else {
            super.deleteBackward(sender)
            return
        }
        stripList(from: paragraphRange, basedOn: style)
    }

    /// Removes the list (and its hanging indent) from the paragraph, and
    /// resets typing attributes so continued typing is body text.
    private func stripList(from paragraphRange: NSRange, basedOn style: NSParagraphStyle) {
        let plain = plainStyle(from: style)
        textStorage?.addAttribute(.paragraphStyle, value: plain, range: paragraphRange)
        typingAttributes[.paragraphStyle] = plain
    }

    private func plainStyle(from style: NSParagraphStyle) -> NSMutableParagraphStyle {
        let plain = (style.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        plain.textLists = []
        plain.headIndent = 0
        plain.firstLineHeadIndent = 0
        return plain
    }
}
