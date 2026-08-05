import XCTest
@testable import SwiftMaestro

final class ToolArgumentRepairTests: XCTestCase {

    func testValidJSONObjectIsUnchanged() {
        let input = #"{"query":"Swift 6.3 release notes","max_results":5}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), input)
    }

    func testStringWrappedJSONObjectIsUnwrapped() {
        let input = #""{\"query\":\"Swift 6.3 release notes\"}""#
        let expected = #"{"query":"Swift 6.3 release notes"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testKeyWithLeadingQuoteBraceIsCleaned() {
        // Model emitted a key that accidentally includes `"{` before the
        // intended parameter name: { "\"{\"query": "value" }
        let input = "{\"\\\"{\\\"query\":\"Swift 6.3 release notes\"}"
        let expected = #"{"query":"Swift 6.3 release notes"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testKeyWithLeadingQuoteOnlyIsCleaned() {
        // Model emitted a key like `"query` (valid JSON, but wrong key).
        let input = "{\"\\\"query\":\"Swift 6.3 release notes\"}"
        let expected = #"{"query":"Swift 6.3 release notes"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testMultipleMalformedKeysAreCleaned() {
        let input = "{\"\\\"{\\\"query\":\"Swift 6.3\",\"\\\"{\\\"max_results\":3}"
        let result = ToolArgumentRepair.repair(input)
        // Both keys should be cleaned and the inner JSON should be valid.
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("result is not valid JSON: \(result)")
            return
        }
        XCTAssertEqual(obj["query"] as? String, "Swift 6.3")
        XCTAssertEqual(obj["max_results"] as? Int, 3)
    }

    func testEmptyStringReturnsEmptyObject() {
        XCTAssertEqual(ToolArgumentRepair.repair(""), "{}")
        XCTAssertEqual(ToolArgumentRepair.repair("   \n\t  "), "{}")
    }

    func testInvalidJSONReturnedUnchanged() {
        let input = "not json at all"
        XCTAssertEqual(ToolArgumentRepair.repair(input), input)
    }

    func testValuePrefixedWithKeyAndQuotesIsStripped() {
        let input = #"{"query":"query=\"Swift 6.3 release notes latest features\""}"#
        let expected = #"{"query":"Swift 6.3 release notes latest features"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testValuePrefixedWithKeyAndUnbalancedQuotesIsStripped() {
        let input = #"{"query":"query=\"Swift 6.3 release notes latest features"}"#
        let expected = #"{"query":"Swift 6.3 release notes latest features"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testValuePrefixedWithKeyWithoutQuotesIsStripped() {
        let input = #"{"query":"query=Swift 6.3 release notes latest features"}"#
        let expected = #"{"query":"Swift 6.3 release notes latest features"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), expected)
    }

    func testValueWithoutPrefixIsUnchanged() {
        let input = #"{"query":"Swift 6.3 release notes latest features"}"#
        XCTAssertEqual(ToolArgumentRepair.repair(input), input)
    }

    // MARK: - sanitizeAgentURL

    func testSanitizeAgentURLCleanPassthrough() {
        let url = "https://www.thefront.com.au/mirrorless-cameras"
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(url), url)
    }

    func testSanitizeAgentURLPreservesQueryAndTrailingSlash() {
        let url = "https://www.thefront.com.au/search?q=Canon+EOS+R5+Mark+II"
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(url), url)
        let slash = "https://lunarstudios.au/collections/rental/"
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(slash), slash)
    }

    func testSanitizeAgentURLSingleLayerJunk() {
        // Production round 12 form (decoded): quote/backslash wrapper + escaped slashes.
        let input = #"\"https:\/\/thefront.com.au\"}"#
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(input), "https://thefront.com.au")
    }

    func testSanitizeAgentURLNestedEscapeLayers() {
        // Production round 26 form: escaping COMPOUNDED across rounds — a single
        // cleaning pass leaves `https:\/\/\/host` residue; the fixpoint loop must
        // fully recover the URL.
        let input = #"\\\"https:\\\/\\\/thefront.com.au\\\/collections\\\/lighting\\\"}"#
        XCTAssertEqual(
            ToolArgumentRepair.sanitizeAgentURL(input),
            "https://thefront.com.au/collections/lighting")
    }

    func testSanitizeAgentURLPercentEncodedQuoteJunk() {
        let input = "%22https://rentacam.sydney%22"
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(input), "https://rentacam.sydney")
    }

    func testSanitizeAgentURLLegitimateEncodingPreserved() {
        // Only %22 (quote) is stripped — real percent-encoding survives.
        let url = "https://example.com/search?q=hello%20world&lang=en"
        XCTAssertEqual(ToolArgumentRepair.sanitizeAgentURL(url), url)
    }

    // MARK: - priceSignalCount

    func testPriceSignalCountFindsDollarAmounts() {
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "Canon R5 II — from $90/day"), 1)
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "B1 from $95/day and $250/week"), 2)
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "Daily rate $ 250, deposit required"), 1)
    }

    func testPriceSignalCountFindsAUDAmounts() {
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "AUD 1200 per week"), 1)
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "Rates: AUD 90 / AUD 450 / AUD 1,200"), 3)
    }

    func testPriceSignalCountZeroOnPriceFreeText() {
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "Welcome to our studio hub in Sydney"), 0)
        XCTAssertEqual(MaestroTools.priceSignalCount(in: "Rent for 3 days or 4 weeks"), 0)
        XCTAssertEqual(MaestroTools.priceSignalCount(in: ""), 0)
    }

    // MARK: - repairValue leading junk & balance-aware trailing (17-round meltdown family)

    private func repairedValue(_ json: String, key: String) -> String? {
        let repaired = ToolArgumentRepair.repair(json)
        guard let data = repaired.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }

    func testLeadingBackslashQuoteJunkIsStripped() {
        // Production round 9: value was \"Representatives (backslash-first — the
        // old hasPrefix("\"") check missed it entirely).
        let input = #"{"table":"\\\"Representatives"}"#
        XCTAssertEqual(repairedValue(input, key: "table"), "Representatives")
    }

    func testNestedEscapeLayersInValueAreStripped() {
        // Production round 18+: value was \\\"text\"} (escape compounding).
        let input = #"{"type":"\\\\\\\"text\\\\\\\"}"}"#
        XCTAssertEqual(repairedValue(input, key: "type"), "text")
    }

    func testTrailingUnbalancedBraceIsStillStripped() {
        let input = #"{"name":"Rental Prices\"}"}"#
        XCTAssertEqual(repairedValue(input, key: "name"), "Rental Prices")
    }

    func testBalancedParenthesisIsPreserved() {
        // Balance-aware trailing strip: "Daily Rate (AUD)" must keep its ")" —
        // the old unconditional strip broke parenthetical field names/types.
        let input = #"{"name":"Daily Rate (AUD)"}"#
        XCTAssertEqual(repairedValue(input, key: "name"), "Daily Rate (AUD)")
    }

    // MARK: - normalizedGuardSignature

    func testNormalizedGuardSignatureCollapsesEscapeGrowth() {
        // The 17-round meltdown: each retry re-escapes the same values, so the
        // raw signatures looked different and every loop counter reset.
        let first = AgentExecutor.normalizedGuardSignature(#"db_add_field|{"type":"\"text"}"#)
        let deeper = AgentExecutor.normalizedGuardSignature(#"db_add_field|{"type":"\\\\\\\"text\\\\\\\"}"}"#)
        XCTAssertEqual(first, deeper)
    }

    func testNormalizedGuardSignatureKeepsDistinctContentDistinct() {
        let a = AgentExecutor.normalizedGuardSignature(#"db_add_field|{"name":"electorate"}"#)
        let b = AgentExecutor.normalizedGuardSignature(#"db_add_field|{"name":"division"}"#)
        XCTAssertNotEqual(a, b)
    }
}
