import Foundation
import Testing
@testable import SwiftMaestro

// MARK: - MaestroDB Relations tests
//
// Title derivation, row resolution, and CSV round-tripping for .relation
// fields — the shared paths the grid editor, db_* tools, and CSV all use.
// Throwaway temp databases only; the shared singleton is never touched.

@Suite("MaestroDBRelations")
struct MaestroDBRelationTests {

    private func makeTempDB() throws -> (MaestroDBDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maestrodb-relation-test-\(UUID().uuidString)", isDirectory: true)
        return (try MaestroDBDatabase.open(dir.appendingPathComponent("test.sqlite")), dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Clients table (text title field) with two rows + a Jobs table linked
    /// to it via a relation field. Returns everything tests need.
    private struct Fixture {
        let clients: DBTable
        let clientName: DBField
        let jobs: DBTable
        let linkField: DBField
        let acme: DBRow
        let globex: DBRow
    }

    private func makeFixture(_ db: MaestroDBDatabase) throws -> Fixture {
        let base = try db.createBase(name: "B")
        let clients = try db.createTable(baseID: base.id, name: "Clients")
        let clientName = try db.addField(tableID: clients.id, name: "Name", type: .text)
        let acme = try db.addRow(tableID: clients.id, values: [clientName.id: "Acme Corp"])
        let globex = try db.addRow(tableID: clients.id, values: [clientName.id: "Globex"])

        let jobs = try db.createTable(baseID: base.id, name: "Jobs")
        let linkField = try db.addField(
            tableID: jobs.id, name: "Client", type: .relation,
            config: ["table": clients.id])
        return Fixture(
            clients: clients, clientName: clientName, jobs: jobs,
            linkField: linkField, acme: acme, globex: globex)
    }

    @Test func titleUsesFirstTextishFieldElseRowN() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)

        let ctx = try #require(MaestroDBRelations.context(for: f.linkField, database: db))
        #expect(ctx.title(for: f.acme.id) == "Acme Corp")
        #expect(ctx.title(for: f.globex.id) == "Globex")
        #expect(ctx.titles.count == 2)
    }

    @Test func contextNilForMissingTargetTable() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let base = try db.createBase(name: "B")
        let table = try db.createTable(baseID: base.id, name: "T")
        let dangling = try db.addField(
            tableID: table.id, name: "Link", type: .relation,
            config: ["table": "no-such-table-id"])
        #expect(MaestroDBRelations.context(for: dangling, database: db) == nil)
    }

    @Test func resolveByIDTitleAndRejectsUnknown() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)

        // Exact row id wins.
        #expect(try MaestroDBRelations.resolveRowID(f.acme.id, field: f.linkField, database: db) == f.acme.id)
        // Title match is case-insensitive.
        #expect(try MaestroDBRelations.resolveRowID("acme corp", field: f.linkField, database: db) == f.acme.id)
        #expect(try MaestroDBRelations.resolveRowID("GLOBEX", field: f.linkField, database: db) == f.globex.id)
        // Empty clears the link.
        #expect(try MaestroDBRelations.resolveRowID("  ", field: f.linkField, database: db) == "")
        // Unknown values resolve to nil.
        #expect(try MaestroDBRelations.resolveRowID("Initech", field: f.linkField, database: db) == nil)
    }

    @Test func csvExportRendersTitlesAndImportResolvesThem() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)

        let jobName = try db.addField(tableID: f.jobs.id, name: "Job", type: .text)
        _ = try db.addRow(tableID: f.jobs.id, values: [
            jobName.id: "Redesign", f.linkField.id: f.acme.id,
        ])

        // Export: relation cell renders the linked row's TITLE.
        let fields = try db.fields(tableID: f.jobs.id)
        let rows = try db.rows(tableID: f.jobs.id)
        let ctx = try #require(MaestroDBRelations.context(for: f.linkField, database: db))
        let csv = MaestroDBCSV.exportCSV(
            fields: fields, rows: rows, relationTitles: [f.linkField.id: ctx.titles])
        #expect(csv.contains("Acme Corp"))
        #expect(!csv.contains(f.acme.id))

        // Re-import into a fresh linked table: the title resolves back to the
        // SAME row id (lossless round-trip).
        let base = try #require(try db.bases().first)
        let copy = try db.createTable(baseID: base.id, name: "Jobs Copy")
        let copyJob = try db.addField(tableID: copy.id, name: "Job", type: .text)
        let copyLink = try db.addField(
            tableID: copy.id, name: "Client", type: .relation,
            config: ["table": f.clients.id])
        let parsed = try MaestroDBCSV.parse(csv)
        let report = try MaestroDBCSV.importRows(parsed, into: copy.id, database: db)
        #expect(report.rowsAdded == 1)
        #expect(report.cellsSkipped == 0)

        let copyRows = try db.rows(tableID: copy.id)
        try #require(copyRows.count == 1)
        #expect(copyRows[0].value(for: copyJob.id) == "Redesign")
        #expect(copyRows[0].value(for: copyLink.id) == f.acme.id)
    }

    @Test func csvImportSkipsUnresolvableLinks() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)

        let jobName = try db.addField(tableID: f.jobs.id, name: "Job", type: .text)
        let csv = "Job,Client\nWebsite,Initech\nStore,Acme Corp\n"
        let parsed = try MaestroDBCSV.parse(csv)
        let report = try MaestroDBCSV.importRows(parsed, into: f.jobs.id, database: db)

        #expect(report.rowsAdded == 2)
        #expect(report.cellsSkipped == 1)
        let rows = try db.rows(tableID: f.jobs.id)
        try #require(rows.count == 2)
        #expect(rows[0].value(for: f.linkField.id).isEmpty)   // Initech: skipped
        #expect(rows[0].value(for: jobName.id) == "Website")  // rest of the row kept
        #expect(rows[1].value(for: f.linkField.id) == f.acme.id)
    }

    @Test func deleteTableCascadesFieldsRowsAndCells() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)
        _ = try db.addRow(tableID: f.jobs.id, values: [f.linkField.id: f.acme.id])

        try db.deleteTable(f.jobs.id)

        #expect(try db.tables(baseID: f.clients.baseID).contains { $0.id == f.jobs.id } == false)
        #expect(try db.fields(tableID: f.jobs.id).isEmpty)
        #expect(try db.rows(tableID: f.jobs.id).isEmpty)
        // The target table is untouched.
        #expect(try db.rows(tableID: f.clients.id).count == 2)
    }

    @Test func deleteBaseCascadesEverythingInside() throws {
        let (db, dir) = try makeTempDB()
        defer { cleanup(dir) }
        let f = try makeFixture(db)
        _ = try db.addRow(tableID: f.jobs.id, values: [f.linkField.id: f.globex.id])

        try db.deleteBase(f.clients.baseID)

        #expect(try db.bases().isEmpty)
        #expect(try db.fields(tableID: f.clients.id).isEmpty)
        #expect(try db.fields(tableID: f.jobs.id).isEmpty)
        #expect(try db.rows(tableID: f.clients.id).isEmpty)
        #expect(try db.rows(tableID: f.jobs.id).isEmpty)
    }
}
