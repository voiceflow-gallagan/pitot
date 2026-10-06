import Foundation
import Testing

@testable import PitotCore

@Suite struct KeybindingsValidatorTests {
    private func makeValidator() throws -> KeybindingsValidator {
        KeybindingsValidator(catalog: try KeybindingsCatalogLoader.load(data: Data(KeybindingsCatalogTests.sample.utf8)))
    }

    private func kinds(_ issues: [KeybindingsValidator.Issue]) -> [KeybindingsValidator.Issue.Kind] {
        issues.map(\.kind)
    }

    @Test func cleanBindingHasNoIssues() throws {
        let validator = try makeValidator()
        #expect(validator.check(context: "Chat", key: "ctrl+e", action: "chat:submit").isEmpty)
        #expect(validator.check(context: "Chat", key: "ctrl+s", action: .null).isEmpty)
    }

    @Test func malformedKeyIsAnError() throws {
        let issues = try makeValidator().check(context: "Chat", key: "ctl+k", action: "chat:submit")
        #expect(kinds(issues) == [.malformedKey])
        #expect(issues.first?.severity == .error)
    }

    @Test func nonStringActionIsAnError() throws {
        let validator = try makeValidator()
        for value: JSONValue in [1, true, ["a"], ["a": 1]] {
            let issues = validator.check(context: "Chat", key: "ctrl+k", action: value)
            #expect(kinds(issues) == [.invalidActionValue])
            #expect(issues.first?.severity == .error)
        }
    }

    @Test func unknownContextIsAWarning() throws {
        let issues = try makeValidator().check(context: "Nowhere", key: "ctrl+k", action: "chat:submit")
        #expect(kinds(issues) == [.unknownContext])
        #expect(issues.first?.severity == .warning)
    }

    @Test func unknownActionIsAWarning() throws {
        let issues = try makeValidator().check(context: "Chat", key: "ctrl+k", action: "chat:levitate")
        #expect(kinds(issues) == [.unknownAction])
        #expect(issues.first?.severity == .warning)
    }

    @Test func reservedKeyIsAWarning() throws {
        let validator = try makeValidator()
        for key in ["ctrl+c", "Ctrl+C", "control+c"] {
            let issues = validator.check(context: "Chat", key: key, action: "chat:submit")
            #expect(kinds(issues) == [.reservedKey])
            #expect(issues.first?.severity == .warning)
        }
    }

    @Test func duplicateKeyUsesNormalizedComparison() throws {
        let validator = try makeValidator()
        let issues = validator.check(context: "Chat", key: "Ctrl+K", action: "chat:submit", existingKeys: ["control+k"])
        #expect(kinds(issues) == [.duplicateKey])
        #expect(issues.first?.severity == .warning)
        #expect(validator.check(context: "Chat", key: "ctrl+k", action: "chat:submit", existingKeys: ["ctrl+j"]).isEmpty)
    }

    @Test func fileCheckFlagsDuplicatesOnlyInTheSameContext() throws {
        let document = try JSONScanner.scan(Array("""
            {"bindings": [
              {"context": "Chat", "bindings": {"ctrl+k": "chat:submit", "Ctrl+K": null}},
              {"context": "Global", "bindings": {"ctrl+k": "app:exit"}},
              {"context": "Chat", "bindings": {"CONTROL+k": "chat:submit"}}
            ]}
            """))
        let located = try makeValidator().check(file: KeybindingsFile(document: document))
        #expect(located.map(\.block) == [0, 2])
        #expect(located.map(\.key) == ["Ctrl+K", "CONTROL+k"])
        #expect(located.allSatisfy { $0.issue.kind == .duplicateKey })
    }
}
