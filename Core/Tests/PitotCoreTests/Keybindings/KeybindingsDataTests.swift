import Foundation
import Testing

@testable import PitotCore

@Suite struct KeybindingsDataTests {
    private func loadCatalog() throws -> KeybindingsCatalog {
        let bytes = try Fixtures.bytes(atRepoPath: "Catalog/keybindings.json")
        return try KeybindingsCatalogLoader.load(data: Data(bytes))
    }

    @Test func realCatalogLintsClean() throws {
        let catalog = try loadCatalog()
        #expect(KeybindingsCatalogLoader.lint(catalog).isEmpty)
        #expect(catalog.docURL == "https://code.claude.com/docs/en/keybindings")
        #expect(catalog.header.schema == "https://www.schemastore.org/claude-code-keybindings.json")
    }

    @Test func realCatalogHasPlausibleCounts() throws {
        let catalog = try loadCatalog()
        #expect(catalog.contexts.count >= 20)
        #expect(catalog.actions.count >= 110)
        #expect(catalog.action(id: "chat:submit")?.contexts == ["Chat"])
        #expect(catalog.action(id: "app:interrupt")?.defaultKey == "Ctrl+C")
        #expect(catalog.reservedKeys.count == 7)
        #expect(catalog.reservedKeys.filter { !$0.writable }.map(\.key) == ["Caps Lock"])
    }

    @Test func realCatalogMarksLegacyActionsAndContextDefaults() throws {
        let catalog = try loadCatalog()
        let legacy = catalog.actions.filter(\.legacy).map(\.id)
        #expect(legacy.count == 6)
        #expect(catalog.action(id: "messageSelector:select")?.replacedBy == "select:accept")
        #expect(catalog.action(id: "select:accept")?.defaultKey == "Enter")
        #expect(catalog.action(id: "select:accept")?.contextDefaults == ["Settings": "Enter, Space"])
        #expect(catalog.action(id: "scroll:top")?.contextDefaults == ["DiffDialog": "G, Home", "Scroll": "Ctrl+Home"])
        #expect(catalog.action(id: "scroll:fullPageDown")?.contextDefaults == ["DiffDialog": "Space"])
        #expect(catalog.action(id: "confirm:cycleMode")?.description.hasSuffix("...") == false)
    }

    @Test func realCatalogSampleFileIsClean() throws {
        let validator = KeybindingsValidator(catalog: try loadCatalog())
        let document = try JSONScanner.scan(Array("""
            {
              "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
              "bindings": [{"context": "Chat", "bindings": {"ctrl+e": "chat:externalEditor", "ctrl+s": null}}]
            }
            """))
        #expect(try validator.check(file: KeybindingsFile(document: document)).isEmpty)
    }
}
