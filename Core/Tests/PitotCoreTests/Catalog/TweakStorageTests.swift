import Foundation
import Testing

@testable import PitotCore

@Suite("Tweak storage")
struct TweakStorageTests {
    let catalog: Catalog

    init() throws {
        catalog = try CatalogSamples.catalog()
    }

    private func tweak(_ id: String) throws -> Tweak {
        try #require(catalog.tweak(id: id))
    }

    private func reading(_ id: String, in text: String) throws -> TweakReading {
        try tweak(id).reading(in: CatalogSamples.document(text))
    }

    @Test func readsSettingsByType() throws {
        let text = #"{"tui": "fullscreen", "cleanupPeriodDays": 14, "plansDirectory": "docs/plans", "sandbox": {"enabled": true}}"#

        #expect(try reading("tui", in: text) == .value("fullscreen"))
        #expect(try reading("cleanupPeriodDays", in: text) == .value(14))
        #expect(try reading("plansDirectory", in: text) == .value("docs/plans"))
        #expect(try reading("sandbox.enabled", in: text) == .value(true))
    }

    @Test func absentKeyIsUnset() throws {
        #expect(try reading("tui", in: "{}") == .unset)
        #expect(try reading("sandbox.enabled", in: #"{"sandbox": {}}"#) == .unset)
        #expect(try reading("sandbox.enabled", in: #"{"sandbox": "on"}"#) == .unset)
        #expect(try reading("disableTelemetry", in: #"{"env": {}}"#) == .unset)
    }

    @Test func wrongJSONKindIsUnrecognized() throws {
        #expect(try reading("tui", in: #"{"tui": 5}"#) == .unrecognized(5))
        #expect(try reading("sandbox.enabled", in: #"{"sandbox": {"enabled": "yes"}}"#) == .unrecognized("yes"))
        #expect(try reading("cleanupPeriodDays", in: #"{"cleanupPeriodDays": 1.5}"#) == .unrecognized(.number(try #require(JSONNumber(text: "1.5")))))
        #expect(try reading("disableTelemetry", in: #"{"env": {"DISABLE_TELEMETRY": 1}}"#) == .unrecognized(1))
    }

    @Test("an env flag is on for any non-empty value, even 0", arguments: ["1", "0", "true", "false", "anything"])
    func flagIsOnWhenNonEmpty(value: String) throws {
        #expect(try reading("disableTelemetry", in: #"{"env": {"DISABLE_TELEMETRY": "\#(value)"}}"#) == .value(true))
    }

    @Test func emptyEnvFlagIsOff() throws {
        #expect(try reading("disableTelemetry", in: #"{"env": {"DISABLE_TELEMETRY": ""}}"#) == .value(false))
    }

    @Test(
        "an env bool accepts the documented words",
        arguments: [("1", true), ("true", true), ("YES", true), ("on", true), ("0", false), ("false", false), ("no", false), ("Off", false)])
    func envBoolWords(text: String, expected: Bool) throws {
        #expect(try reading("noFlicker", in: #"{"env": {"CLAUDE_CODE_NO_FLICKER": "\#(text)"}}"#) == .value(.bool(expected)))
    }

    @Test func unknownEnvBoolWordIsUnrecognized() throws {
        #expect(try reading("noFlicker", in: #"{"env": {"CLAUDE_CODE_NO_FLICKER": "maybe"}}"#) == .unrecognized("maybe"))
    }

    @Test func envIntegerAndStringReadFromStrings() throws {
        let integer = CatalogSamples.envInteger
        #expect(integer.reading(in: try CatalogSamples.document(#"{"env": {"BASH_DEFAULT_TIMEOUT_MS": "120000"}}"#)) == .value(120000))
        #expect(integer.reading(in: try CatalogSamples.document(#"{"env": {"BASH_DEFAULT_TIMEOUT_MS": "2m"}}"#)) == .unrecognized("2m"))
        #expect(try reading("subagentModel", in: #"{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"}}"#) == .value("sonnet"))
    }

    @Test func editValuesFollowTheLocation() throws {
        #expect(try tweak("sandbox.enabled").editValue(for: true) == .json(true))
        #expect(try tweak("cleanupPeriodDays").editValue(for: 7) == .json(7))
        #expect(try tweak("tui").editValue(for: "fullscreen") == .json("fullscreen"))
        #expect(try tweak("noFlicker").editValue(for: true) == .json("1"))
        #expect(try tweak("noFlicker").editValue(for: false) == .json("0"))
        #expect(CatalogSamples.envInteger.editValue(for: 120000) == .json("120000"))
        #expect(try tweak("subagentModel").editValue(for: "sonnet") == .json("sonnet"))
    }

    @Test func flagOnWritesOneAndOffRemoves() throws {
        let flag = try tweak("disableTelemetry")

        #expect(flag.editValue(for: true) == .json("1"))
        #expect(flag.editValue(for: false) == nil)
        #expect(flag.operation(for: true) == .set(path: ["env", "DISABLE_TELEMETRY"], value: .json("1")))
        #expect(flag.operation(for: false) == .remove(path: ["env", "DISABLE_TELEMETRY"]))
    }

    @Test("a flag never writes 0", arguments: [TweakValue.bool(true), .bool(false), .integer(0), .integer(1), .string("0"), .string(""), .string("off")])
    func flagNeverWritesZero(value: TweakValue) throws {
        let operation = try tweak("disableTelemetry").operation(for: value)

        if case .set(_, let edit, _) = operation {
            #expect(edit == .json("1"))
        }
    }

    @Test func nilValueRemovesTheKey() throws {
        #expect(try tweak("sandbox.enabled").operation(for: nil) == .remove(path: ["sandbox", "enabled"]))
    }

    @Test func operationInDocumentSkipsWhatTheFileAlreadyMeans() throws {
        let document = try CatalogSamples.document(#"{"tui": "fullscreen", "env": {"CLAUDE_CODE_NO_FLICKER": "true", "DISABLE_TELEMETRY": "0"}}"#)

        #expect(try tweak("tui").operation(for: "fullscreen", in: document) == nil)
        #expect(try tweak("noFlicker").operation(for: true, in: document) == nil)
        #expect(try tweak("disableTelemetry").operation(for: true, in: document) == nil)
        #expect(try tweak("plansDirectory").operation(for: nil, in: document) == nil)
        #expect(try tweak("tui").operation(for: "default", in: document) == .set(path: ["tui"], value: .json("default")))
        #expect(try tweak("noFlicker").operation(for: false, in: document) == .set(path: ["env", "CLAUDE_CODE_NO_FLICKER"], value: .json("0")))
        #expect(try tweak("disableTelemetry").operation(for: false, in: document) == .remove(path: ["env", "DISABLE_TELEMETRY"]))
    }

    @Test func writtenValuesReadBack() throws {
        let cases: [(String, TweakValue)] = [
            ("tui", "fullscreen"), ("sandbox.enabled", false), ("cleanupPeriodDays", 9), ("noFlicker", false),
            ("disableTelemetry", true), ("subagentModel", "opus"), ("permissions.disableBypassPermissionsMode", true),
        ]
        var bytes = [UInt8]("{\n  \"theme\": \"dark\"\n}\n")
        for (id, value) in cases {
            bytes = try JSONEdit.apply(try tweak(id).operation(for: value), to: bytes).bytes
        }
        let document = try JSONScanner.scan(bytes)

        for (id, value) in cases {
            #expect(try tweak(id).reading(in: document) == .value(value), "\(id)")
        }
        #expect(document.value(at: ["env", "DISABLE_TELEMETRY"]) == "1")
        #expect(document.value(at: ["env", "CLAUDE_CODE_NO_FLICKER"]) == "0")
        #expect(document.value(at: ["permissions", "disableBypassPermissionsMode"]) == "disable")
    }

    // MARK: fixedString

    @Test func fixedStringReadsOnOnlyForItsExactValue() throws {
        let id = "permissions.disableBypassPermissionsMode"

        #expect(try reading(id, in: #"{"permissions": {"disableBypassPermissionsMode": "disable"}}"#) == .value(true))
        #expect(try reading(id, in: #"{"permissions": {}}"#) == .unset)
        #expect(try reading(id, in: #"{"permissions": {"disableBypassPermissionsMode": "Disable"}}"#) == .unrecognized("Disable"))
        #expect(try reading(id, in: #"{"permissions": {"disableBypassPermissionsMode": ""}}"#) == .unrecognized(""))
        #expect(try reading(id, in: #"{"permissions": {"disableBypassPermissionsMode": true}}"#) == .unrecognized(true))
    }

    @Test func fixedStringReadsFromEnv() throws {
        let tweak = CatalogSamples.envFixedString

        #expect(tweak.reading(in: try CatalogSamples.document(#"{"env": {"SOME_SWITCH": "disable"}}"#)) == .value(true))
        #expect(tweak.reading(in: try CatalogSamples.document(#"{"env": {"SOME_SWITCH": "1"}}"#)) == .unrecognized("1"))
        #expect(tweak.editValue(for: true) == .json("disable"))
    }

    @Test func fixedStringOnWritesTheStringAndOffRemoves() throws {
        let fixed = try tweak("permissions.disableBypassPermissionsMode")
        let path = ["permissions", "disableBypassPermissionsMode"]

        #expect(fixed.editValue(for: true) == .json("disable"))
        #expect(fixed.editValue(for: false) == nil)
        #expect(fixed.operation(for: true) == .set(path: path, value: .json("disable")))
        #expect(fixed.operation(for: false) == .remove(path: path))
        #expect(fixed.operation(for: nil) == .remove(path: path))
    }

    @Test("a fixed string writes nothing but its value", arguments: [TweakValue.bool(true), .bool(false), .integer(1), .string("other"), .string("")])
    func fixedStringWritesOnlyItsValue(value: TweakValue) throws {
        if case .set(_, let edit, _) = try tweak("permissions.disableBypassPermissionsMode").operation(for: value) {
            #expect(edit == .json("disable"))
        }
    }

    @Test func fixedStringOperationInDocument() throws {
        let fixed = try tweak("permissions.disableBypassPermissionsMode")
        let path = ["permissions", "disableBypassPermissionsMode"]
        let on = try CatalogSamples.document(#"{"permissions": {"disableBypassPermissionsMode": "disable"}}"#)
        let other = try CatalogSamples.document(#"{"permissions": {"disableBypassPermissionsMode": "yes"}}"#)

        #expect(fixed.operation(for: true, in: on) == nil)
        #expect(fixed.operation(for: false, in: on) == .remove(path: path))
        #expect(fixed.operation(for: true, in: other) == .set(path: path, value: .json("disable")))
        #expect(fixed.operation(for: false, in: other) == .remove(path: path))
        #expect(fixed.operation(for: false, in: try CatalogSamples.document("{}")) == nil)
    }
}
