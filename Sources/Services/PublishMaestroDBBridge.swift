import Foundation
import GRDB

/// Two-way bridge between the Publish app and a special MaestroDB "Publish" base.
///
/// The base contains:
///   - Drafts table: every tracked draft with Status, Tags, Feed, etc.
///   - Tags table: monitored tags and their workflow role/color.
///   - Feeds table: configured output feeds.
///
/// Edits in MaestroDB (status changes, tag edits, feed assignments) are pulled
/// back into PublishStore; PublishStore mutations push forward to MaestroDB.
@MainActor
final class PublishMaestroDBBridge {

    static let shared = PublishMaestroDBBridge()

    private let database = MaestroDBDatabase.shared
    private var isApplyingDBChanges = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dbDidChange),
            name: .maestroDBDidChange,
            object: nil
        )
    }

    // MARK: - Public sync

    /// Bidirectional sync: apply DB edits to PublishStore, then push the current
    /// store state back to MaestroDB.
    func sync() async {
        do {
            try await pullFromDB()
            pushToDB()
        } catch {
            PublishStore.shared.lastError = error.localizedDescription
            NSLog("[PUBLISH-DB-BRIDGE] sync failed: \(error)")
        }
    }

    /// Push PublishStore state to MaestroDB without reading DB changes first.
    /// Call this after any PublishStore mutation that should be reflected in DB.
    func pushToDB() {
        guard !isApplyingDBChanges else { return }
        isApplyingDBChanges = true
        defer { isApplyingDBChanges = false }

        do {
            let base = try ensureBase()
            let draftsTable = try ensureDraftsTable(baseID: base.id)
            let tagsTable = try ensureTagsTable(baseID: base.id)
            let feedsTable = try ensureFeedsTable(baseID: base.id)

            try pushTags(to: tagsTable)
            try pushFeeds(to: feedsTable)
            try pushDrafts(to: draftsTable)

            NotificationCenter.default.post(name: .maestroDBDidChange, object: nil)
        } catch {
            PublishStore.shared.lastError = error.localizedDescription
            NSLog("[PUBLISH-DB-BRIDGE] push failed: \(error)")
        }
    }

    // MARK: - Pull from DB

    private func pullFromDB() async throws {
        let base = try ensureBase()
        guard let draftsTable = try database.tables(baseID: base.id).first(where: { $0.name == TableNames.drafts }) else { return }

        let fields = try database.fields(tableID: draftsTable.id)
        let rows = try database.rows(tableID: draftsTable.id)

        let store = PublishStore.shared
        isApplyingDBChanges = true
        defer { isApplyingDBChanges = false }

        for row in rows {
            let sourcePath = row.value(for: fields.id(named: FieldNames.sourcePath))
            guard !sourcePath.isEmpty else { continue }

            guard let draftIndex = store.drafts.firstIndex(where: { $0.sourcePath == sourcePath }) else { continue }
            let draft = store.drafts[draftIndex]

            let dbModifiedAt = Date(timeIntervalSince1970: row.number(for: fields.id(named: FieldNames.modifiedAt)) ?? draft.modifiedAt.timeIntervalSince1970)
            guard dbModifiedAt > draft.modifiedAt else { continue }

            // Status
            if let status = Self.status(from: row.value(for: fields.id(named: FieldNames.status))) {
                store.drafts[draftIndex].status = status
                if status == .published, store.drafts[draftIndex].publishedAt == nil {
                    store.drafts[draftIndex].publishedAt = dbModifiedAt
                }
            }

            // Tags
            let tagValues = row.multiValues(for: fields.id(named: FieldNames.tags))
            if !tagValues.isEmpty {
                store.drafts[draftIndex].tags = tagValues
            }

            // Feed
            let feedName = row.value(for: fields.id(named: FieldNames.feed))
            if !feedName.isEmpty, let feed = store.feeds.first(where: { $0.name == feedName }) {
                store.drafts[draftIndex].feedID = feed.id
            }

            // Title / summary / body (DB wins if newer)
            let title = row.value(for: fields.id(named: FieldNames.title))
            if !title.isEmpty { store.drafts[draftIndex].title = title }
            let summary = row.value(for: fields.id(named: FieldNames.summary))
            if !summary.isEmpty { store.drafts[draftIndex].summary = summary }
            let bodyHTML = row.value(for: fields.id(named: FieldNames.bodyHTML))
            if !bodyHTML.isEmpty { store.drafts[draftIndex].bodyHTML = bodyHTML }

            let publishedAt = row.number(for: fields.id(named: FieldNames.publishedAt))
            store.drafts[draftIndex].publishedAt = publishedAt.map { Date(timeIntervalSince1970: $0) }

            store.drafts[draftIndex].modifiedAt = dbModifiedAt
        }

        store.saveDrafts()
    }

    // MARK: - Push helpers

    private func pushTags(to table: DBTable) throws {
        let fields = try database.fields(tableID: table.id)
        let nameField = fields.id(named: FieldNames.tagName)
        let roleField = fields.id(named: FieldNames.tagRole)
        let colorField = fields.id(named: FieldNames.tagColor)
        let updatedAtField = fields.id(named: FieldNames.tagUpdatedAt)

        let existingRows = try database.rows(tableID: table.id)
        for row in existingRows {
            try database.deleteRow(row.id)
        }

        for tag in PublishStore.shared.tags {
            let values: [String: String] = [
                nameField: tag.name,
                roleField: tag.role?.displayName ?? "",
                colorField: tag.color?.rawValue ?? "default",
                updatedAtField: DBRow.store(Date().timeIntervalSince1970)
            ]
            _ = try database.addRow(tableID: table.id, values: values)
        }
    }

    private func pushFeeds(to table: DBTable) throws {
        let fields = try database.fields(tableID: table.id)
        let nameField = fields.id(named: FieldNames.feedName)
        let dirField = fields.id(named: FieldNames.feedOutputDirectory)
        let updatedAtField = fields.id(named: FieldNames.feedUpdatedAt)

        let existingRows = try database.rows(tableID: table.id)
        for row in existingRows {
            try database.deleteRow(row.id)
        }

        for feed in PublishStore.shared.feeds {
            let values: [String: String] = [
                nameField: feed.name,
                dirField: feed.outputDirectory ?? "",
                updatedAtField: DBRow.store(Date().timeIntervalSince1970)
            ]
            _ = try database.addRow(tableID: table.id, values: values)
        }
    }

    private func pushDrafts(to table: DBTable) throws {
        let fields = try database.fields(tableID: table.id)
        let f = FieldIDProvider(fields: fields)

        let existingRows = try database.rows(tableID: table.id)
        var rowBySourcePath: [String: DBRow] = [:]
        for row in existingRows {
            let path = row.value(for: f.sourcePath)
            if !path.isEmpty { rowBySourcePath[path] = row }
        }

        let store = PublishStore.shared
        var seenSourcePaths = Set<String>()

        for draft in store.drafts {
            seenSourcePaths.insert(draft.sourcePath)
            let values: [String: String] = [
                f.sourcePath: draft.sourcePath,
                f.title: draft.title,
                f.sourceKind: draft.sourceKind.displayName,
                f.status: draft.status.displayName,
                f.tags: DBRow.store(multi: draft.tags),
                f.feed: feedName(for: draft.feedID),
                f.summary: draft.summary,
                f.bodyHTML: draft.bodyHTML,
                f.publishedAt: draft.publishedAt.map { DBRow.store($0.timeIntervalSince1970) } ?? "",
                f.modifiedAt: DBRow.store(draft.modifiedAt.timeIntervalSince1970)
            ]

            if let existing = rowBySourcePath[draft.sourcePath] {
                try updateRow(existing, values: values)
            } else {
                let newRow = try database.addRow(tableID: table.id, values: values)
                try setRowTimestamp(rowID: newRow.id, timestamp: draft.modifiedAt)
            }
        }

        // Remove DB rows for drafts that no longer exist in PublishStore.
        for (path, row) in rowBySourcePath where !seenSourcePaths.contains(path) {
            try database.deleteRow(row.id)
        }
    }

    private func updateRow(_ row: DBRow, values: [String: String]) throws {
        for (fieldID, value) in values {
            if row.value(for: fieldID) != value {
                try database.setCell(rowID: row.id, fieldID: fieldID, value: value)
            }
        }
        if let modifiedAt = values[FieldNames.modifiedAt],
           let interval = Double(modifiedAt) {
            try setRowTimestamp(rowID: row.id, timestamp: Date(timeIntervalSince1970: interval))
        }
    }

    private func setRowTimestamp(rowID: String, timestamp: Date) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE db_row SET updated_at = ? WHERE id = ?",
                arguments: [timestamp.timeIntervalSince1970, rowID]
            )
        }
    }

    // MARK: - Schema creation

    private func ensureBase() throws -> MaestroBase {
        if let existing = try database.bases().first(where: { $0.name == publishBaseName }) {
            return existing
        }
        return try database.createBase(name: publishBaseName, icon: publishBaseIcon)
    }

    private func ensureDraftsTable(baseID: String) throws -> DBTable {
        let table = try ensureTable(name: TableNames.drafts, baseID: baseID)
        let statusOptions = PublishStatus.allCases.map(\.displayName)
        let sourceKindOptions = PublishSourceKind.allCases.map(\.displayName)
        let feedOptions = PublishStore.shared.feeds.map(\.name)

        _ = try ensureField(name: FieldNames.sourcePath, type: .text, tableID: table.id)
        _ = try ensureField(name: FieldNames.title, type: .text, tableID: table.id)
        _ = try ensureField(name: FieldNames.sourceKind, type: .select, options: sourceKindOptions, tableID: table.id)
        _ = try ensureField(name: FieldNames.status, type: .select, options: statusOptions, tableID: table.id)
        _ = try ensureField(name: FieldNames.tags, type: .multiSelect, tableID: table.id)
        _ = try ensureField(name: FieldNames.feed, type: .select, options: feedOptions, tableID: table.id)
        _ = try ensureField(name: FieldNames.summary, type: .longText, tableID: table.id)
        _ = try ensureField(name: FieldNames.bodyHTML, type: .longText, tableID: table.id)
        _ = try ensureField(name: FieldNames.publishedAt, type: .number, tableID: table.id)
        _ = try ensureField(name: FieldNames.modifiedAt, type: .number, tableID: table.id)
        return table
    }

    private func ensureTagsTable(baseID: String) throws -> DBTable {
        let table = try ensureTable(name: TableNames.tags, baseID: baseID)
        let roleOptions = PublishTagRole.allCases.map(\.displayName)
        let colorOptions = KanbanColumnColor.allCases.map(\.rawValue)

        _ = try ensureField(name: FieldNames.tagName, type: .text, tableID: table.id)
        _ = try ensureField(name: FieldNames.tagRole, type: .select, options: roleOptions, tableID: table.id)
        _ = try ensureField(name: FieldNames.tagColor, type: .select, options: colorOptions, tableID: table.id)
        _ = try ensureField(name: FieldNames.tagUpdatedAt, type: .number, tableID: table.id)
        return table
    }

    private func ensureFeedsTable(baseID: String) throws -> DBTable {
        let table = try ensureTable(name: TableNames.feeds, baseID: baseID)
        _ = try ensureField(name: FieldNames.feedName, type: .text, tableID: table.id)
        _ = try ensureField(name: FieldNames.feedOutputDirectory, type: .longText, tableID: table.id)
        _ = try ensureField(name: FieldNames.feedUpdatedAt, type: .number, tableID: table.id)
        return table
    }

    private func ensureTable(name: String, baseID: String) throws -> DBTable {
        if let existing = try database.tables(baseID: baseID).first(where: { $0.name == name }) {
            return existing
        }
        return try database.createTable(baseID: baseID, name: name)
    }

    @discardableResult
    private func ensureField(name: String, type: DBFieldType, options: [String] = [], tableID: String) throws -> DBField {
        if let existing = try database.fields(tableID: tableID).first(where: { $0.name == name }) {
            for option in options where !existing.options.contains(option) {
                try database.addFieldOption(existing.id, option: option)
            }
            return existing
        }
        return try database.addField(tableID: tableID, name: name, type: type, options: options, config: [:])
    }

    // MARK: - Mapping helpers

    private static func status(from string: String) -> PublishStatus? {
        PublishStatus.allCases.first { $0.displayName == string || $0.rawValue == string }
    }

    private func feedName(for feedID: UUID?) -> String {
        guard let feedID else { return "" }
        return PublishStore.shared.feeds.first { $0.id == feedID }?.name ?? ""
    }

    @objc @MainActor private func dbDidChange() {
        guard !isApplyingDBChanges else { return }
        Task { await sync() }
    }
}

// MARK: - Names

private let publishBaseName = "Publish"
private let publishBaseIcon = "newspaper"

private enum TableNames {
    static let drafts = "Drafts"
    static let tags = "Tags"
    static let feeds = "Feeds"
}

private enum FieldNames {
    static let sourcePath = "Source Path"
    static let title = "Title"
    static let sourceKind = "Source Kind"
    static let status = "Status"
    static let tags = "Tags"
    static let feed = "Feed"
    static let summary = "Summary"
    static let bodyHTML = "Body HTML"
    static let publishedAt = "Published At"
    static let modifiedAt = "Modified At"

    static let tagName = "Name"
    static let tagRole = "Role"
    static let tagColor = "Color"
    static let tagUpdatedAt = "Updated At"

    static let feedName = "Name"
    static let feedOutputDirectory = "Output Directory"
    static let feedUpdatedAt = "Updated At"
}

// MARK: - Field helpers

private struct FieldIDProvider {
    let sourcePath: String
    let title: String
    let sourceKind: String
    let status: String
    let tags: String
    let feed: String
    let summary: String
    let bodyHTML: String
    let publishedAt: String
    let modifiedAt: String

    init(fields: [DBField]) {
        sourcePath = fields.id(named: FieldNames.sourcePath)
        title = fields.id(named: FieldNames.title)
        sourceKind = fields.id(named: FieldNames.sourceKind)
        status = fields.id(named: FieldNames.status)
        tags = fields.id(named: FieldNames.tags)
        feed = fields.id(named: FieldNames.feed)
        summary = fields.id(named: FieldNames.summary)
        bodyHTML = fields.id(named: FieldNames.bodyHTML)
        publishedAt = fields.id(named: FieldNames.publishedAt)
        modifiedAt = fields.id(named: FieldNames.modifiedAt)
    }
}

private extension [DBField] {
    func id(named name: String) -> String {
        first { $0.name == name }?.id ?? ""
    }
}

private extension [PublishTag] {
}
