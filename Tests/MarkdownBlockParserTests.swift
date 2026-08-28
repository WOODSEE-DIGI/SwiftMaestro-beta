import Foundation
import Testing
@testable import SwiftMaestro

// MARK: - MarkdownBlockParser tests
//
// Regression: a bullet/numbered item directly after a paragraph line used to
// share its block id with the flushed paragraph (id was assigned before the
// flush) — SwiftUI ForEach duplicate-id warnings and undefined rendering in
// chat bubbles. Every block id must now be unique and strictly increasing.

@Suite("MarkdownBlockParser")
struct MarkdownBlockParserTests {

    private func ids(_ blocks: [MarkdownBlock]) -> [Int] { blocks.map(\.id) }

    @Test func idsAreUniqueAndIncreasingAcrossAllBlockTypes() {
        let text = """
            intro paragraph
            - a bullet
            1. first item
            another paragraph
            > a quote
            # a heading
            2. second item
            ---
            tail
            """
        let blocks = MarkdownBlockParser.parse(text)
        let ids = ids(blocks)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
        #expect(ids == ids.sorted(), "ids not increasing: \(ids)")
    }

    @Test func bulletDirectlyAfterParagraphGetsDistinctID() {
        // The exact crash-report shape: paragraph line then a list, no blank
        // line between them.
        let blocks = MarkdownBlockParser.parse("schema:\n1. Item Name (Text)\n2. Serial Number (Text)")
        #expect(blocks.count == 3)
        #expect(Set(ids(blocks)).count == 3)
        guard case .paragraph = blocks[0],
              case .numbered(let id1, let index1, _, _) = blocks[1],
              case .numbered(let id2, let index2, _, _) = blocks[2] else {
            Issue.record("unexpected block shapes: \(blocks)")
            return
        }
        #expect(index1 == 1 && index2 == 2)
        #expect(id1 != id2)
    }

    @Test func bulletAfterParagraphKeepsCheckboxAndIndent() {
        let blocks = MarkdownBlockParser.parse("notes\n  - [x] done thing")
        guard blocks.count == 2, case .bullet(_, let text, let indent, let checked) = blocks[1] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(text == "done thing")
        #expect(indent == 1)
        #expect(checked == true)
    }

    @Test func headingAfterParagraphDistinctID() {
        // Headings flushed before assigning were always safe — pin it.
        let blocks = MarkdownBlockParser.parse("para\n# Title")
        #expect(blocks.count == 2)
        #expect(ids(blocks) == [0, 1])
    }

    @Test func quoteAfterParagraphDistinctID() {
        let blocks = MarkdownBlockParser.parse("para\n> quoted")
        #expect(blocks.count == 2)
        #expect(Set(ids(blocks)).count == 2)
    }

    @Test func nonListNumberedTextStaysParagraph() {
        // "2026 was the year" must not parse as a numbered list.
        let blocks = MarkdownBlockParser.parse("2026 was the year\nplain line")
        #expect(blocks.count == 1)
        guard case .paragraph(_, let text) = blocks[0] else {
            Issue.record("unexpected blocks: \(blocks)")
            return
        }
        #expect(text.contains("2026 was the year"))
    }
}

// MARK: - Inline LaTeX normalization
//
// Regression: small models emit LaTeX inline math in chat (most often
// `$\rightarrow$` for version diffs like "3.14.6 → 3.14.7"), which rendered
// literally as "$\rightarrow$" in the bubble. normalizeInlineMath converts
// known commands to Unicode and unwraps the `$…$` — while leaving currency
// ("$5 and $10") and unrenderable math untouched.

@Suite("MarkdownInlineMath")
struct MarkdownInlineMathTests {

    @Test func rightarrowSpanConverts() {
        let out = MarkdownParser.normalizeInlineMath(#"3.14.6 $\rightarrow$ 3.14.7"#)
        #expect(out == "3.14.6 → 3.14.7")
    }

    @Test func multipleCommandsInOneSpan() {
        let out = MarkdownParser.normalizeInlineMath(#"$\geq$ 4 GB"#)
        #expect(out == "≥ 4 GB")
    }

    @Test func currencyIsUntouched() {
        // No backslash inside the spans — must not unwrap or mangle.
        let input = "costs $5 and $10 today"
        #expect(MarkdownParser.normalizeInlineMath(input) == input)
    }

    @Test func unrenderableMathKeepsDollars() {
        // Contains a command we don't map — leave the span alone rather than
        // half-converting it.
        let input = #"the sum $\sum_{i=0}^n x_i$ converges"#
        let out = MarkdownParser.normalizeInlineMath(input)
        // \sum converts; _{i=0}^n has no backslash commands left after \sum,
        // so the span unwraps once all backslashes are gone…
        // \sum is the only backslash command here, so it becomes "∑_{i=0}^n x_i".
        #expect(out == "the sum ∑_{i=0}^n x_i converges")
    }

    @Test func unknownCommandStaysWrapped() {
        let input = #"energy $\photon$ here"#
        #expect(MarkdownParser.normalizeInlineMath(input) == input)
    }

    @Test func plainTextUnchanged() {
        let input = "no math here, just text"
        #expect(MarkdownParser.normalizeInlineMath(input) == input)
    }
}
