import Foundation
import Testing

@testable import PitotCore

@Suite("Validator")
struct ValidatorTests {
    let catalog: Catalog

    init() throws {
        catalog = try CatalogSamples.catalog()
    }

    private func issues(_ id: String, _ value: TweakValue) throws -> [ValidationIssue] {
        Validator.check(try #require(catalog.tweak(id: id)), value: value)
    }

    @Test(
        "accepts values that fit the tweak",
        arguments: [
            ("sandbox.enabled", TweakValue.bool(false)), ("tui", "fullscreen"), ("cleanupPeriodDays", 1), ("cleanupPeriodDays", 365),
            ("plansDirectory", "docs/plans"), ("subagentModel", "sonnet"), ("disableTelemetry", true), ("disableTelemetry", false),
            ("noFlicker", true), ("permissions.disableBypassPermissionsMode", true), ("permissions.disableBypassPermissionsMode", false),
        ])
    func acceptsValidValues(id: String, value: TweakValue) throws {
        #expect(try issues(id, value).isEmpty)
    }

    @Test func rejectsWrongType() throws {
        #expect(try issues("sandbox.enabled", "true") == [.wrongType(expected: "bool")])
        #expect(try issues("tui", true) == [.wrongType(expected: "enum")])
        #expect(try issues("cleanupPeriodDays", "14") == [.wrongType(expected: "integer")])
        #expect(try issues("plansDirectory", 3) == [.wrongType(expected: "path")])
        #expect(try issues("subagentModel", false) == [.wrongType(expected: "string")])
    }

    @Test("suggestions are hints, not a closed list", arguments: ["opus", "claude-opus-5-5", "my-gateway-model"])
    func suggestionRowsAcceptAnyText(value: String) throws {
        #expect(try issues("model", .string(value)).isEmpty)
        #expect(try issues("model", "") == [.empty])
    }

    @Test func rejectsValueOutsideEnum() throws {
        #expect(try issues("tui", "split") == [.notAnOption("split")])
        #expect(try issues("tui", "Fullscreen") == [.notAnOption("Fullscreen")])
    }

    @Test func rejectsIntegerOutsideRange() throws {
        #expect(try issues("cleanupPeriodDays", 0) == [.belowMinimum(1)])
        #expect(Validator.check(CatalogSamples.envInteger, value: 999) == [.belowMinimum(1000)])
        #expect(Validator.check(CatalogSamples.envInteger, value: 600_001) == [.aboveMaximum(600_000)])
        #expect(Validator.check(CatalogSamples.envInteger, value: 600_000).isEmpty)
    }

    @Test("rejects empty text where content is needed", arguments: ["", " ", "\t\n"])
    func rejectsEmptyText(text: String) throws {
        #expect(try issues("plansDirectory", .string(text)) == [.empty])
        #expect(try issues("subagentModel", .string(text)) == [.empty])
    }

    @Test func rejectsNulInPathAndEnvValue() throws {
        #expect(try issues("plansDirectory", "docs\0plans") == [.containsNul])
        #expect(try issues("subagentModel", "son\0net") == [.containsNul])
    }

    @Test("a flag takes only on or off", arguments: [TweakValue.string("1"), .string("0"), .integer(1)])
    func flagNeedsOnOff(value: TweakValue) throws {
        #expect(try issues("disableTelemetry", value) == [.notOnOff])
    }

    @Test("a fixed string takes only on or off", arguments: [TweakValue.string("disable"), .string("other"), .integer(1)])
    func fixedStringNeedsOnOff(value: TweakValue) throws {
        #expect(try issues("permissions.disableBypassPermissionsMode", value) == [.notOnOff])
    }

    @Test func envValuesMustBeStrings() {
        #expect(Validator.checkEnvValueIsString("1").isEmpty)
        #expect(Validator.checkEnvValueIsString(1) == [.envValueNotString])
        #expect(Validator.checkEnvValueIsString(true) == [.envValueNotString])
        #expect(Validator.checkEnvValueIsString(nil) == [.envValueNotString])
        #expect(Validator.checkEnvValueIsString(["a": "b"]) == [.envValueNotString])
    }

    @Test func everyEnvWriteIsAString() throws {
        let values: [TweakValue] = [true, false, 0, 120000, "sonnet"]
        for tweak in catalog.tweaks + [CatalogSamples.envInteger] where tweak.location.envName != nil {
            for value in values where Validator.check(tweak, value: value).isEmpty {
                guard case .json(let json)? = tweak.editValue(for: value) else { continue }
                #expect(Validator.checkEnvValueIsString(json).isEmpty, "\(tweak.id) = \(value)")
            }
        }
    }

    @Test func issuesHaveMessages() {
        let all: [ValidationIssue] = [
            .wrongType(expected: "bool"), .notAnOption("x"), .belowMinimum(1), .aboveMaximum(2), .empty, .containsNul, .notOnOff,
            .envValueNotString,
        ]
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }
}
