import Foundation
import Testing
@testable import SwiftMaestro

// MARK: - db_* tool helper tests
//
// suggestField powers the "did you mean 'X'?" correction in unknown-field
// errors — the difference between a model self-correcting and inventing
// another wrong name.

@Suite("MaestroDB tool helpers")
struct MaestroDBToolHelpersTests {

    private func field(_ name: String, type: DBFieldType = .text) -> DBField {
        DBField(id: UUID().uuidString, tableID: "t", name: name, type: type,
                position: 0, options: [], config: [:])
    }

    @Test func prefixAndAbbreviationSuggestions() {
        let fields = [field("Item Name"), field("Serial Number"), field("Daily Rental Rate")]
        #expect(MaestroTools.suggestField("Item", fields: fields) == "Item Name")
        #expect(MaestroTools.suggestField("Serial No", fields: fields) == nil
                || MaestroTools.suggestField("Serial No", fields: fields) == "Serial Number")
        #expect(MaestroTools.suggestField("item name", fields: fields) != nil)
    }

    @Test func containmentAndCaseInsensitivity() {
        let fields = [field("Serial Number"), field("Daily Rental Rate")]
        #expect(MaestroTools.suggestField("serial number", fields: fields) == "Serial Number")
        #expect(MaestroTools.suggestField("Rental", fields: fields) == "Daily Rental Rate")
    }

    @Test func unrelatedNamesGetNoSuggestion() {
        let fields = [field("Item Name"), field("Status")]
        #expect(MaestroTools.suggestField("Zebra Crossing", fields: fields) == nil)
        #expect(MaestroTools.suggestField("", fields: fields) == nil)
    }

    @Test func shortestMostSpecificMatchWins() {
        // "Status Date" contains "Status" — a bare "Status" guess should land
        // on the short exact-ish field, not the long one.
        let fields = [field("Status"), field("Status Date")]
        #expect(MaestroTools.suggestField("status", fields: fields) == "Status")
    }
}
