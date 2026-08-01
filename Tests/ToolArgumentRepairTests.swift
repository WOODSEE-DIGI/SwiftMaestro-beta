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
}
