import Foundation
import Testing

@testable import PitotCore

@Suite struct KeybindingsCatalogTests {
    static let sample = """
        {
          "researchDate": "2026-10-06",
          "claudeCodeVersionChecked": "2.1.291",
          "docURL": "https://code.claude.com/docs/en/keybindings",
          "header": {"schema": "https://example.test/schema.json", "docs": "https://code.claude.com/docs/en/keybindings"},
          "contexts": [{"name": "Chat", "description": "Main chat input area"}, {"name": "Global", "description": "Everywhere"}],
          "actions": [
            {"id": "chat:submit", "namespace": "chat", "contexts": ["Chat"], "description": "Submit message", "defaultKey": "Enter"},
            {"id": "app:exit", "namespace": "app", "contexts": ["Global"], "description": "Exit Claude Code"}
          ],
          "keySyntax": {
            "modifiers": ["ctrl", "shift", "alt", "cmd"],
            "aliases": {"control": "ctrl"},
            "specialKeys": ["enter", "tab"],
            "chordSeparator": " ",
            "notes": []
          },
          "reservedKeys": [{"key": "ctrl+c", "reason": "Interrupt"}]
        }
        """

    private func load(_ text: String) throws(KeybindingsCatalogError) -> KeybindingsCatalog {
        try KeybindingsCatalogLoader.load(data: Data(text.utf8))
    }

    private func lintRules(of text: String) throws -> [KeybindingsLintIssue.Rule] {
        let catalog = try KeybindingsCatalogLoader.decode(data: Data(text.utf8))
        return KeybindingsCatalogLoader.lint(catalog).map(\.rule)
    }

    @Test func loadsValidCatalog() throws {
        let catalog = try load(Self.sample)
        #expect(catalog.contexts.map(\.name) == ["Chat", "Global"])
        #expect(catalog.action(id: "chat:submit")?.defaultKey == "Enter")
        #expect(catalog.action(id: "app:exit")?.defaultKey == nil)
        #expect(catalog.header.schema == "https://example.test/schema.json")
    }

    @Test func rejectsUnknownTopLevelKey() {
        let text = Self.sample.replacingOccurrences(of: "\"researchDate\"", with: "\"surprise\": 1, \"researchDate\"")
        #expect(throws: KeybindingsCatalogError.self) { try load(text) }
        #expect(throws: KeybindingsCatalogError.malformed(path: "surprise", reason: "Unknown key \"surprise\"")) { try load(text) }
    }

    @Test func rejectsUnknownNestedKey() {
        let text = Self.sample.replacingOccurrences(of: "\"description\": \"Exit Claude Code\"", with: "\"description\": \"Exit Claude Code\", \"extra\": true")
        #expect(throws: KeybindingsCatalogError.malformed(path: "actions[1].extra", reason: "Unknown key \"extra\"")) { try load(text) }
    }

    @Test func reportsMissingKey() {
        let text = Self.sample.replacingOccurrences(of: "\"docURL\": \"https://code.claude.com/docs/en/keybindings\",", with: "")
        #expect(throws: KeybindingsCatalogError.malformed(path: "docURL", reason: "Missing key \"docURL\"")) { try load(text) }
    }

    @Test func lintFlagsMissingDocURL() throws {
        let text = Self.sample.replacingOccurrences(of: "\"docURL\": \"https://code.claude.com/docs/en/keybindings\"", with: "\"docURL\": \"\"")
        #expect(try lintRules(of: text) == [.missingDocURL])
        #expect(throws: KeybindingsCatalogError.self) { try load(text) }
    }

    @Test func lintFlagsDuplicateActionId() throws {
        let text = Self.sample.replacingOccurrences(of: "\"id\": \"app:exit\", \"namespace\": \"app\"", with: "\"id\": \"chat:submit\", \"namespace\": \"chat\"")
        #expect(try lintRules(of: text) == [.duplicateActionId])
    }

    @Test func lintFlagsUnknownContext() throws {
        let text = Self.sample.replacingOccurrences(of: "\"contexts\": [\"Global\"]", with: "\"contexts\": [\"Nowhere\"]")
        #expect(try lintRules(of: text) == [.unknownContext])
    }

    @Test func lintFlagsNamespaceMismatch() throws {
        let text = Self.sample.replacingOccurrences(of: "\"namespace\": \"app\"", with: "\"namespace\": \"chat\"")
        #expect(try lintRules(of: text) == [.namespaceMismatch])
    }

    @Test func readsLegacyContextDefaultsAndUnwritableReservedKey() throws {
        var text = Self.sample.replacingOccurrences(
            of: "\"description\": \"Exit Claude Code\"}",
            with: "\"description\": \"Exit\", \"legacy\": true, \"replacedBy\": \"chat:submit\", \"contextDefaults\": {\"Global\": \"Ctrl+D\"}}")
        text = text.replacingOccurrences(of: "{\"key\": \"ctrl+c\", \"reason\": \"Interrupt\"}", with: "{\"key\": \"Caps Lock\", \"reason\": \"Not sent\", \"writable\": false}")
        let catalog = try load(text)
        let action = try #require(catalog.action(id: "app:exit"))
        #expect(action.legacy)
        #expect(action.replacedBy == "chat:submit")
        #expect(action.contextDefaults == ["Global": "Ctrl+D"])
        #expect(catalog.action(id: "chat:submit")?.legacy == false)
        #expect(catalog.reservedKeys.first?.writable == false)
    }

    @Test func lintFlagsLegacyWithoutValidReplacement() throws {
        let missing = Self.sample.replacingOccurrences(of: "\"description\": \"Exit Claude Code\"}", with: "\"description\": \"Exit\", \"legacy\": true}")
        #expect(try lintRules(of: missing) == [.invalidLegacy])
        let unknown = Self.sample.replacingOccurrences(of: "\"description\": \"Exit Claude Code\"}", with: "\"description\": \"Exit\", \"legacy\": true, \"replacedBy\": \"nope:x\"}")
        #expect(try lintRules(of: unknown) == [.invalidLegacy])
        let orphan = Self.sample.replacingOccurrences(of: "\"description\": \"Exit Claude Code\"}", with: "\"description\": \"Exit\", \"replacedBy\": \"chat:submit\"}")
        #expect(try lintRules(of: orphan) == [.invalidLegacy])
    }

    @Test func lintFlagsContextDefaultOutsideContexts() throws {
        let text = Self.sample.replacingOccurrences(of: "\"description\": \"Exit Claude Code\"}", with: "\"description\": \"Exit\", \"contextDefaults\": {\"Chat\": \"x\"}}")
        #expect(try lintRules(of: text) == [.unknownContextDefault])
    }

    @Test func lintFlagsInvalidReservedKey() throws {
        let text = Self.sample.replacingOccurrences(of: "\"key\": \"ctrl+c\"", with: "\"key\": \"ctl+c\"")
        #expect(try lintRules(of: text) == [.invalidKey])
    }

    @Test func lintFlagsDuplicateContextAndEmptyDescription() throws {
        let text = Self.sample.replacingOccurrences(
            of: "{\"name\": \"Global\", \"description\": \"Everywhere\"}",
            with: "{\"name\": \"Chat\", \"description\": \"\"}")
        let rules = try lintRules(of: text)
        #expect(rules.contains(.duplicateContext))
        #expect(rules.contains(.emptyDescription))
    }
}
