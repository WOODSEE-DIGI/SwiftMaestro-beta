import Foundation
import Testing
@testable import SwiftMaestro

// MARK: - Panel-driven (Auto) tool category tests
//
// Drives WorkspaceStore.effectiveCategories (the pure filter) — never the
// live WorkspaceLayoutState, which persists on every mutation and must not
// be touched by tests.

@Suite("Auto tool categories")
struct AutoToolCategoryTests {

    // MARK: Mapping sanity

    @Test func everyLinkedCategoryHasAtLeastOnePanel() {
        for category in ToolCategory.allCases where category.isPanelLinked {
            #expect(!category.linkedPanelKinds.isEmpty)
        }
    }

    @Test func expectedPanelMappings() {
        #expect(ToolCategory.books.linkedPanelKinds == [.maestroBooks])
        #expect(ToolCategory.database.linkedPanelKinds == [.maestroDB])
        #expect(ToolCategory.kanban.linkedPanelKinds == [.kanban])
        #expect(ToolCategory.browser.linkedPanelKinds == [.webBrowser])
        // Notes answers to either panel.
        #expect(ToolCategory.notes.linkedPanelKinds == [.notesMD, .appleNotes])
    }

    @Test func coreCategoriesAreNotPanelLinked() {
        for core in [ToolCategory.file, .shell, .memory, .workspace, .system,
                     .sqlite, .index, .web, .vault, .rules, .time, .messaging,
                     .bus, .server, .mcp] {
            #expect(!core.isPanelLinked, "\(core) should stay manual under Auto")
        }
    }

    // MARK: Effective-set filter

    @Test func autoOffPassesSavedThrough() {
        let saved: Set<ToolCategory> = [.books, .database, .memory]
        let effective = WorkspaceStore.effectiveCategories(
            saved: saved, auto: false) { _ in false }
        #expect(effective == saved)
    }

    @Test func autoOnStripsClosedPanels() {
        let saved: Set<ToolCategory> = [.books, .database, .memory, .file]
        let effective = WorkspaceStore.effectiveCategories(
            saved: saved, auto: true) { $0 == .maestroDB }
        // MaestroDB panel open → kept; Books panel closed → stripped.
        // Core categories unaffected either way.
        #expect(effective == [.database, .memory, .file])
    }

    @Test func notesEnabledByEitherPanel() {
        let saved: Set<ToolCategory> = [.notes]
        let viaAppleNotes = WorkspaceStore.effectiveCategories(
            saved: saved, auto: true) { $0 == .appleNotes }
        let viaNotesMD = WorkspaceStore.effectiveCategories(
            saved: saved, auto: true) { $0 == .notesMD }
        let neither = WorkspaceStore.effectiveCategories(
            saved: saved, auto: true) { _ in false }
        #expect(viaAppleNotes == [.notes])
        #expect(viaNotesMD == [.notes])
        #expect(neither.isEmpty)
    }

    @Test func agentRecordDefaultsToAutoOn() throws {
        // nil (including JSON written before this field) means Auto is on.
        let record = AgentRecord(name: "Test", kind: .project)
        #expect(record.autoToolCategories == nil)
        let legacyJSON = """
            {"id": "\(UUID().uuidString)", "name": "Old", "kind": "project"}
            """
        let decoded = try JSONDecoder().decode(
            AgentRecord.self, from: Data(legacyJSON.utf8))
        #expect(decoded.autoToolCategories == nil)
    }
}
