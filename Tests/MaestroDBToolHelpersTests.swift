import Foundation
import Testing
import MLXLMCommon
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

    // MARK: Lenient argument decoding (db_add_rows / db_add_row)
    //
    // Regression: Gemma 4 sends db_add_rows 'rows' as a NATIVE JSON array —
    // [{"Name": "Ada", "Rate": 250}] — but AddRowsArgs.rows was String?, so
    // the whole Codable decode failed and the tool reported the misleading
    // "requires 'table' and 'rows'" six times in a row. The lenient decoder
    // must accept the native array AND keep accepting the legacy string form.

    private func toolCall(argumentsJSON: String) -> ToolCall {
        let data = Data(argumentsJSON.utf8)
        let dict = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
        return ToolCall(function: .init(name: "test", arguments: dict))
    }

    @Test func addRowsAcceptsNativeArray() throws {
        let call = toolCall(argumentsJSON: """
            {"table": "Rental Prices", "base_id": "ABC-123",
             "rows": [{"Item Name": "Canon EOS R5 Mark II", "Daily Rate": 250},
                      {"Item Name": "Profoto B1", "Daily Rate": 90}]}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.AddRowsArgs.self))
        #expect(args.table == "Rental Prices")
        #expect(args.base_id == "ABC-123")
        let rowsRaw = try #require(args.rows)
        let parsed = try JSONSerialization.jsonObject(with: Data(rowsRaw.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?.first?["Item Name"] as? String == "Canon EOS R5 Mark II")
        #expect(parsed?.first?["Daily Rate"] as? Int == 250)
    }

    @Test func addRowsStillAcceptsLegacyStringForm() throws {
        // Some models wrap the array in a quoted JSON string — must keep working.
        let call = toolCall(argumentsJSON: """
            {"table": "Rental Prices",
             "rows": "[{\\"Item Name\\": \\"Profoto B1\\", \\"Daily Rate\\": 90}]"}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.AddRowsArgs.self))
        let rowsRaw = try #require(args.rows)
        let parsed = try JSONSerialization.jsonObject(with: Data(rowsRaw.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect(parsed?.first?["Item Name"] as? String == "Profoto B1")
    }

    @Test func rowValuesAcceptsNativeObject() throws {
        let call = toolCall(argumentsJSON: """
            {"table": "Rental Prices",
             "values": {"Item Name": "Canon EOS R5 Mark II", "Daily Rate": 250, "In Stock": true}}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.RowValuesArgs.self))
        let valuesRaw = try #require(args.values)
        let parsed = try JSONSerialization.jsonObject(with: Data(valuesRaw.utf8)) as? [String: Any]
        #expect(parsed?["Item Name"] as? String == "Canon EOS R5 Mark II")
        #expect(parsed?["Daily Rate"] as? Int == 250)
        #expect(parsed?["In Stock"] as? Bool == true)
    }

    // MARK: Key-alias decoding (db_add_field / db_create_table)
    //
    // Regression: Gemma 4 called db_add_field 16 times with 'field_name'
    // (never 'name') — the tool is called db_add_FIELD, so that's the natural
    // key it invents. The failure breaker disabled the tool, the table stayed
    // field-less, and the model worked around it with a CSV import instead of
    // telling the user. Aliases must decode to the canonical keys.

    @Test func addFieldAcceptsFieldNameAlias() throws {
        let call = toolCall(argumentsJSON: """
            {"base": "Example Camera Rentals", "table": "Rental Rates",
             "field_name": "Rental House", "type": "text"}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.AddFieldArgs.self))
        #expect(args.name == "Rental House")
        #expect(args.table == "Rental Rates")
        #expect(args.type == "text")
    }

    @Test func addFieldAcceptsAllAliases() throws {
        let call = toolCall(argumentsJSON: """
            {"base": "B", "table_name": "T", "field_name": "F", "field_type": "number"}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.AddFieldArgs.self))
        #expect(args.table == "T")
        #expect(args.name == "F")
        #expect(args.type == "number")
    }

    // MARK: Field-spread salvage (db_add_rows)
    //
    // Regression: under payload pressure Gemma 4 spread the row's fields as
    // TOP-LEVEL arguments next to a truncated 'rows' string:
    //   {"table":"Rental Prices", "Equipment":"\\\"Profoto B1",
    //    "Price (AUD)":"90", "rows":"[{\\\"Date Monitored..."}
    // The salvage path collects the extra top-level keys as ONE row, and
    // stripModelJunk cleans the edge escape junk off the values.

    @Test func stripModelJunkCleansEdgeEscapes() {
        #expect(MaestroTools.stripModelJunk("\\\"Profoto B1") == "Profoto B1")
        #expect(MaestroTools.stripModelJunk("\\\"2025-05-22") == "2025-05-22")
        #expect(MaestroTools.stripModelJunk("Example Rental House") == "Example Rental House")
        #expect(MaestroTools.stripModelJunk("https://example.com/page") == "https://example.com/page")
    }

    @Test func stringifyDictStripsValueJunk() throws {
        let cleaned = MaestroTools.stringifyJSONDict([
            "Equipment": "\\\"Profoto B1",
            "Price (AUD)": 90,
            "In Stock": true,
        ])
        #expect(cleaned["Equipment"] == "Profoto B1")
        #expect(cleaned["Price (AUD)"] == "90")
        #expect(cleaned["In Stock"] == "true")
    }

    // MARK: Record-date field matching
    //
    // Gemma 4 stamped "Date Monitored" as 2025-05-22 (hallucinated) in
    // August 2026. Record-semantics date fields get auto-stamped when empty
    // and suspicion-warned when wildly off — but Due/Expiry/Published dates
    // are legitimately not today and must NOT match.

    @Test func recordDateFieldMatching() {
        #expect(MaestroTools.isRecordDateField("Date Monitored") == true)
        #expect(MaestroTools.isRecordDateField("Date Found") == true)
        #expect(MaestroTools.isRecordDateField("date added") == true)
        #expect(MaestroTools.isRecordDateField("Logged") == true)
        // Legitimately-not-today fields must NOT match:
        #expect(MaestroTools.isRecordDateField("Due Date") == false)
        #expect(MaestroTools.isRecordDateField("Expiry") == false)
        #expect(MaestroTools.isRecordDateField("Published") == false)
        #expect(MaestroTools.isRecordDateField("Price (AUD)") == false)
    }

    @Test func todayISOIsWellFormed() {
        let iso = MaestroTools.todayISO
        #expect(iso.count == 10)
        #expect(iso.split(separator: "-").count == 3)
        #expect(MaestroDBCoercion.parseDate(iso) != nil)
    }

    // MARK: Embedded-number extraction (price coercion)
    //
    // The model sent "Price (AUD)" values like "$250/day" — Double() rejected
    // them, the cell was skipped, and the model reacted by re-adding the same
    // field five times. extractEmbeddedNumber salvages the price instead of
    // dropping the cell.

    @Test func embeddedNumberExtraction() {
        #expect(MaestroDBCoercion.extractEmbeddedNumber("$250/day") == 250)
        #expect(MaestroDBCoercion.extractEmbeddedNumber("from $16/day") == 16)
        #expect(MaestroDBCoercion.extractEmbeddedNumber("AUD 90") == 90)
        #expect(MaestroDBCoercion.extractEmbeddedNumber("AUD 1,250.00") == 1250)
        #expect(MaestroDBCoercion.extractEmbeddedNumber("250") == 250)
        #expect(MaestroDBCoercion.extractEmbeddedNumber("Contact for price") == nil)
    }

    @Test func numberCoercionAcceptsDecoratedPrices() {
        #expect(MaestroDBCoercion.canonical("$250/day", for: .number) != nil)
        #expect(MaestroDBCoercion.canonical("AUD 90", for: .number) != nil)
        #expect(MaestroDBCoercion.canonical("Contact for price", for: .number) == nil)
        // Plain numbers still take the strict path:
        #expect(MaestroDBCoercion.canonical("250", for: .number) != nil)
    }

    // MARK: Field-name auto-mapping
    //
    // Eleven date-only husk rows landed because the model sent keys that
    // didn't exactly match the field names and coerceValues only SUGGESTED
    // corrections without applying them. suggestField must resolve every
    // failure-mode name so the auto-map branch recovers the value.

    @Test func autoMapResolvesFailureModeNames() {
        let fields = [
            field("Rental House"), field("Equipment Name"),
            field("Daily Rate (AUD)", type: .number),
            field("Date Found", type: .date), field("Source URL", type: .url),
        ]
        #expect(MaestroTools.suggestField("rental_house", fields: fields) == "Rental House")
        #expect(MaestroTools.suggestField("Equipment", fields: fields) == "Equipment Name")
        #expect(MaestroTools.suggestField("Daily Rate", fields: fields) == "Daily Rate (AUD)")
        #expect(MaestroTools.suggestField("daily_rate", fields: fields) == "Daily Rate (AUD)")
        #expect(MaestroTools.suggestField("Source", fields: fields) == "Source URL")
        #expect(MaestroTools.suggestField("url", fields: fields) == "Source URL")
    }

    // MARK: db_upsert_rows args decoding
    //
    // The monitoring workflow tool — re-running research must UPDATE matched
    // rows, never duplicate them. Same lenient rows decoding as db_add_rows.

    @Test func upsertRowsAcceptsNativeArrayAndKey() throws {
        let call = toolCall(argumentsJSON: """
            {"table": "Rental Prices", "key": "Equipment Name",
             "rows": [{"Equipment Name": "Canon EOS R5 Mark II", "Daily Rate (AUD)": 245},
                      {"Equipment Name": "Profoto B1", "Daily Rate (AUD)": 90}]}
            """)
        let args = try #require(MaestroTools.decodeArgs(call, as: MaestroTools.UpsertRowsArgs.self))
        #expect(args.table == "Rental Prices")
        #expect(args.key == "Equipment Name")
        let rowsRaw = try #require(args.rows)
        let parsed = try JSONSerialization.jsonObject(with: Data(rowsRaw.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?.first?["Equipment Name"] as? String == "Canon EOS R5 Mark II")
    }

    // MARK: parseRowsArray meltdown salvage
    //
    // The 04:47 run: Gemma 4 wrapped every row as {values:<|"|>{…}<|"|>} with
    // a truncated tail, right when ALL the data was correct (fields, prices,
    // today's date). The sanitizer must strip the tokens, unwrap the values
    // key, and keep the complete prefix when the tail row is cut off.

    @Test func parseRowsArraySalvagesTokenWrappedTruncatedPayload() {
        // Decoded-string form of a representative production-style payload (round 24).
        let payload = """
        [{values:<|"|>{"Equipment Name":"Canon EOS R5 Mark II","Rental House":"Example Rental House","Daily Rate (AUD)":250,"Last Checked":"2026-08-04"}<|"|>},{values:<|"|>{"Equipment Name":"Profoto B1 500 Air","Rental House":"Example Ren
        """
        let rows = MaestroTools.parseRowsArray(payload)
        #expect(rows != nil)
        // Truncated tail row dropped; complete first row survives intact.
        #expect(rows?.count == 1)
        #expect(rows?.first?["Equipment Name"] as? String == "Canon EOS R5 Mark II")
        #expect(rows?.first?["Rental House"] as? String == "Example Rental House")
        #expect(rows?.first?["Daily Rate (AUD)"] as? Int == 250)
        #expect(rows?.first?["Last Checked"] as? String == "2026-08-04")
    }

    @Test func parseRowsArrayPassesCleanPayloadsThrough() {
        let clean = """
        [{"Name":"Ada","Rate":250},{"Name":"Grace","Rate":90}]
        """
        let rows = MaestroTools.parseRowsArray(clean)
        #expect(rows?.count == 2)
        #expect(rows?.first?["Name"] as? String == "Ada")
        #expect(rows?.last?["Rate"] as? Int == 90)
    }

    @Test func parseRowsArraySalvagesTruncatedCleanArray() {
        let truncated = """
        [{"Name":"Ada","Rate":250},{"Name":"Grace","Ra
        """
        let rows = MaestroTools.parseRowsArray(truncated)
        #expect(rows?.count == 1)
        #expect(rows?.first?["Name"] as? String == "Ada")
    }

    @Test func parseRowsArrayRejectsGarbage() {
        #expect(MaestroTools.parseRowsArray("not json at all") == nil)
        #expect(MaestroTools.parseRowsArray("") == nil)
    }

    // MARK: Field-type aliases
    //
    // The model kept sending 'single_select' — identical "unknown type"
    // errors 4-6 times → failure breaker disabled db_add_field mid-setup and
    // the table was left with "No Fields Yet". The type vocabulary the model
    // invents must map onto the API enum.

    @Test func fieldTypeAliases() {
        #expect(MaestroTools.canonicalFieldType("single_select") == "select")
        #expect(MaestroTools.canonicalFieldType("multi_select") == "multiSelect")
        #expect(MaestroTools.canonicalFieldType("integer") == "number")
        #expect(MaestroTools.canonicalFieldType("boolean") == "checkbox")
        #expect(MaestroTools.canonicalFieldType("string") == "text")
        #expect(MaestroTools.canonicalFieldType("datetime") == "date")
        #expect(MaestroTools.canonicalFieldType("currency") == "number")
        #expect(MaestroTools.canonicalFieldType("Single Select") == "select")
        // Canonical types pass through untouched:
        #expect(MaestroTools.canonicalFieldType("select") == "select")
        #expect(MaestroTools.canonicalFieldType("multiSelect") == "multiSelect")
        #expect(MaestroTools.canonicalFieldType("number") == "number")
        // Genuine garbage still rejected:
        #expect(MaestroTools.canonicalFieldType("hologram") == nil)
    }

    // MARK: Structural-collapse detection
    //
    // The 05:53 run: the model splattered rows across the top-level args as
    // giant alternating key/value strings. Lenient salvage inserted "-5"
    // prices and fragmented URLs — and looked like success, so the breaker
    // never stopped the 12-round loop. Detect and fail loudly instead.

    @Test func collapseDetectionCatchesMeltdownKeys() {
        let garbage: [String: JSONValue] = [
            "base_id": .string("C4720E31"),
            "Daily Rate (AUD)\",750,\"Equipment Name\",\"Canon EOS R5 Mark II\",\"Last Checked Date\",\"2026-08-04\"": .string("x"),
        ]
        #expect(MaestroTools.collapsedArgumentKey(garbage, knownKeys: ["base_id", "rows"]) != nil)
    }

    @Test func collapseDetectionIgnoresLegitFieldKeys() {
        let legit: [String: JSONValue] = [
            "table": .string("Rental Prices"),
            "Equipment Name": .string("Canon EOS R5 Mark II"),
            "Daily Rate (AUD": .int(250),
        ]
        #expect(MaestroTools.collapsedArgumentKey(
            legit, knownKeys: ["table", "base", "base_id", "rows"]) == nil)
    }

    // MARK: Field-type inference from names
    //
    // The 13:48 run: six parallel db_add_field calls ALL missing 'type' — the
    // model stripped "(number)" from the prompt's field list into the name arg
    // but never moved it to 'type'. Six identical failures → breaker. Name
    // inference gets all six production names right.

    @Test func fieldTypeInferenceFromNames() {
        // The exact six names from the production failure:
        #expect(MaestroTools.inferFieldType(fromName: "Equipment Name") == "text")
        #expect(MaestroTools.inferFieldType(fromName: "Rental House") == "text")
        #expect(MaestroTools.inferFieldType(fromName: "Daily Rate AUD") == "number")
        #expect(MaestroTools.inferFieldType(fromName: "Weekly Rate AUD") == "number")
        #expect(MaestroTools.inferFieldType(fromName: "Source URL") == "url")
        #expect(MaestroTools.inferFieldType(fromName: "Last Checked") == "date")
        // Broader coverage:
        #expect(MaestroTools.inferFieldType(fromName: "Price") == "number")
        #expect(MaestroTools.inferFieldType(fromName: "Date Found") == "date")
        #expect(MaestroTools.inferFieldType(fromName: "Notes") == "longText")
        #expect(MaestroTools.inferFieldType(fromName: "Done") == "checkbox")
    }

    // MARK: agentUUID junk stripping
    //
    // The 15:26 run: model emitted tab_id as `\"E74A27FF-…\"}` — literal
    // backslash residue at BOTH ends. UUID parsing failed, strict tab check
    // errored, and the model looped 4 rounds before pivoting to the clean id.
    // agentUUID must strip backslashes along with quotes/braces.

    @Test func agentUUIDStripsBackslashResidue() {
        let clean = "E74A27FF-1FF6-44B6-9665-4D560CBAFE94"
        // Exact production shape: `\"` prefix and `\"}` suffix (post-decode).
        #expect(MaestroTools.agentUUID("\\\"\(clean)\\\"}")?.uuidString == clean)
        // Plain id still works:
        #expect(MaestroTools.agentUUID(clean)?.uuidString == clean)
        // Brace suffix from the earlier base-name saga:
        #expect(MaestroTools.agentUUID("\(clean)\"}")?.uuidString == clean)
        // Genuine garbage still rejected:
        #expect(MaestroTools.agentUUID("not-a-uuid") == nil)
    }
}
