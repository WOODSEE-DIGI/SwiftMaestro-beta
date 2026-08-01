import Foundation
import Testing
@testable import SwiftMaestro

@Suite("ThinkingTagStripper")
struct ThinkingTagStripperTests {

    @Test("strips standalone channel tags")
    func standaloneChannel() {
        #expect(ThinkingTagStripper.strip("<channel>hello") == "hello")
        #expect(ThinkingTagStripper.strip("</channel>hello") == "hello")
        #expect(ThinkingTagStripper.strip("hello<channel>") == "hello")
        #expect(ThinkingTagStripper.strip("hello</channel>") == "hello")
    }

    @Test("strips combined channel+thought tokens")
    func combinedTokens() {
        #expect(ThinkingTagStripper.strip("<channel>thought") == "")
        #expect(ThinkingTagStripper.strip("</channel>thought") == "")
        #expect(ThinkingTagStripper.strip("[channel]thought") == "")
        #expect(ThinkingTagStripper.strip("<|channel|>thought") == "")
    }

    @Test("strips repeated/nested channel opening tags")
    func repeatedOpening() {
        #expect(ThinkingTagStripper.strip("<channel><channel>thought") == "")
        #expect(ThinkingTagStripper.strip("<channel><channel>I have investigated...") == "I have investigated...")
    }

    @Test("strips complete channel reasoning blocks")
    func completeBlocks() {
        let input = "<channel>First thought\nSecond thought</channel>Answer here"
        #expect(ThinkingTagStripper.strip(input) == "Answer here")
    }

    @Test("strips Qwen think blocks")
    func qwenThink() {
        #expect(ThinkingTagStripper.strip("<think>reasoning</think>answer") == "answer")
        #expect(ThinkingTagStripper.strip("</think>answer") == "answer")
    }

    @Test("strips pipe-style channel tags")
    func pipeStyle() {
        #expect(ThinkingTagStripper.strip("<|channel|>reasoning</|channel|>") == "")
        #expect(ThinkingTagStripper.strip("<|channel>reasoning</|channel>") == "")
    }

    @Test("strips bracket-style channel tags")
    func bracketStyle() {
        #expect(ThinkingTagStripper.strip("[channel]reasoning[/channel]") == "")
    }

    @Test("preserves legitimate text and inline words")
    func preservesLegitimateText() {
        #expect(ThinkingTagStripper.strip("I thought about it") == "I thought about it")
        #expect(ThinkingTagStripper.strip("The channel is open") == "The channel is open")
    }

    @Test("collapses excessive blank lines")
    func collapsesBlankLines() {
        #expect(ThinkingTagStripper.strip("a\n\n\n\nb") == "a\n\nb")
    }
}
