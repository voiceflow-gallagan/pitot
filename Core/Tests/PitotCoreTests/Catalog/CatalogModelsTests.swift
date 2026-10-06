import Foundation
import Testing

@testable import PitotCore

@Suite("Catalog models")
struct CatalogModelsTests {
    private func decode(_ text: String) throws(CatalogError) -> Catalog {
        try CatalogLoader.decode(data: Data(text.utf8))
    }

    private func catalogJSON(row: String) -> String {
        #"{"researchDate": "2026-10-05", "claudeCodeVersionChecked": "2.1.291", "tweaks": [\#(row)]}"#
    }

    private let minimalRow = #"""
        {"id": "verbose", "location": {"type": "setting", "path": ["verbose"]}, "valueType": {"type": "bool"},
         "defaultDescription": "false", "title": "Verbose", "description": "Full tool output.", "category": "Interface",
         "risks": [], "status": "documented", "docURL": "https://code.claude.com/docs/en/settings-reference#verbose"}
        """#

    @Test func decodesHandWrittenRow() throws {
        let catalog = try CatalogSamples.catalog()
        let viewMode = try #require(catalog.tweak(id: "viewMode"))

        #expect(catalog.researchDate == "2026-10-05")
        #expect(catalog.claudeCodeVersionChecked == "2.1.291")
        #expect(viewMode.location == .setting(path: ["viewMode"]))
        #expect(
            viewMode.valueType
                == .enumeration([
                    Tweak.Option(value: "default", label: "Default"),
                    Tweak.Option(value: "verbose", label: "Verbose"),
                    Tweak.Option(value: "focus", label: "Focus"),
                ]))
        #expect(viewMode.title == "Starting view")
        #expect(viewMode.category == "Interface")
        #expect(viewMode.risks.isEmpty)
        #expect(viewMode.status == .documented)
        #expect(viewMode.scope == .any)
        #expect(
            viewMode.requires == [
                Tweak.Requirement(tweakId: "tui", when: "focus", equals: "fullscreen", behavior: .autoSet, reason: "Focus view needs the fullscreen renderer.")
            ])
        #expect(viewMode.docURL == "https://code.claude.com/docs/en/settings-reference#viewmode")
    }

    @Test func decodesEveryUnionCase() throws {
        let catalog = try CatalogSamples.catalog()

        #expect(catalog.tweak(id: "disableTelemetry")?.location == .env(name: "DISABLE_TELEMETRY"))
        #expect(catalog.tweak(id: "disableTelemetry")?.valueType == .flag)
        #expect(catalog.tweak(id: "subagentModel")?.valueType == .string)
        #expect(catalog.tweak(id: "plansDirectory")?.valueType == .path)
        #expect(catalog.tweak(id: "permissions.disableBypassPermissionsMode")?.valueType == .fixedString("disable"))
        #expect(catalog.tweak(id: "cleanupPeriodDays")?.valueType == .integer(min: 1, max: nil))
        #expect(catalog.tweak(id: "askUserQuestionTimeout")?.scope == .userOnly)
        #expect(catalog.tweak(id: "subagentModelForce")?.minVersion == "2.1.257")
        #expect(catalog.tweak(id: "subagentModelForce")?.requires == [])
        #expect(catalog.tweak(id: "anthropicBaseURL")?.risks == [.security, .privacy])
        #expect(catalog.tweak(id: "anthropicBaseURL")?.confirm?.appliesWhen == .onAnyChange)
        #expect(catalog.tweak(id: "sandbox.enabled")?.confirm?.appliesWhen == .onDisable)
        #expect(catalog.tweak(id: "sandbox.enabled")?.defaultValue == false)
        #expect(catalog.tweak(id: "tui")?.defaultValue == nil)
        #expect(catalog.tweak(id: "permissions.defaultMode")?.userOnlyValues == ["bypassPermissions"])
        #expect(catalog.tweak(id: "tui")?.userOnlyValues == [])
        #expect(
            catalog.tweak(id: "model")?.suggestions == [
                Tweak.Suggestion(value: "opus", label: "Opus", note: "Latest Opus."),
                Tweak.Suggestion(value: "opusplan", label: "Opus plan", note: "Opus in plan mode, Sonnet otherwise."),
                Tweak.Suggestion(value: "sonnet", label: "Sonnet"),
            ])
        #expect(catalog.tweak(id: "tui")?.suggestions == [])
        #expect(catalog.tweak(id: "permissions.defaultMode")?.confirm?.appliesWhen == .whenValue("bypassPermissions"))
        #expect(catalog.tweak(id: "permissions.defaultMode")?.notes == "auto and bypassPermissions only work from user settings.")
        #expect(catalog.tweak(id: "disableClaudeAiConnectors")?.overriddenBy == [Tweak.EnvOverride(envName: "ENABLE_CLAUDEAI_MCP_SERVERS", whenValue: "false")])
    }

    @Test func requirementWithoutEqualsMeansAnyValue() throws {
        let json = #"{"tweakId": "helper", "behavior": "disable", "reason": "Set a helper first."}"#

        let requirement = try JSONDecoder().decode(Tweak.Requirement.self, from: Data(json.utf8))

        #expect(requirement == Tweak.Requirement(tweakId: "helper", equals: nil, behavior: .disable, reason: "Set a helper first."))
    }

    @Test func roundTripsThroughEncoding() throws {
        let catalog = try CatalogSamples.catalog()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encoded = try encoder.encode(catalog)
        let decoded = try CatalogLoader.decode(data: encoded)

        #expect(decoded == catalog)
        #expect(try encoder.encode(decoded) == encoded)
    }

    @Test func encodesRisksInFixedOrder() throws {
        let tweak = CatalogSamples.tweak("x")
        var risky = tweak
        risky.risks = [.privacy, .cost, .security]

        let text = String(decoding: try JSONEncoder().encode(risky), as: UTF8.self)

        #expect(text.contains(#""risks":["security","cost","privacy"]"#))
    }

    @Test func optionalFieldsTakeDefaults() throws {
        let tweak = try #require(try decode(catalogJSON(row: minimalRow)).tweaks.first)

        #expect(tweak.scope == .any)
        #expect(tweak.minVersion == nil)
        #expect(tweak.requires.isEmpty)
        #expect(tweak.confirm == nil)
        #expect(tweak.overriddenBy.isEmpty)
        #expect(tweak.notes == nil)
    }

    @Test func rejectsUnknownKeySoTyposFail() {
        let row = minimalRow.replacingOccurrences(of: #""risks": []"#, with: #""risks": [], "requries": []"#)

        #expect(throws: CatalogError.malformed(path: "tweaks[0].requries", reason: #"Unknown key "requries""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test func rejectsUnknownValueType() {
        let row = minimalRow.replacingOccurrences(of: #"{"type": "bool"}"#, with: #"{"type": "boolean"}"#)

        #expect(throws: CatalogError.malformed(path: "tweaks[0].valueType.type", reason: #"Unknown value type "boolean""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test func fixedStringNeedsItsValue() {
        let row = minimalRow.replacingOccurrences(of: #"{"type": "bool"}"#, with: #"{"type": "fixedString"}"#)

        #expect(throws: CatalogError.malformed(path: "tweaks[0].valueType.value", reason: #"Missing key "value""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test(
        "a value type rejects keys of another type",
        arguments: [
            (#"{"type": "fixedString", "value": "disable", "options": []}"#, "options", "fixedString"),
            (#"{"type": "bool", "value": "disable"}"#, "value", "bool"),
            (#"{"type": "enum", "options": [], "min": 1}"#, "min", "enum"),
        ])
    func valueTypeRejectsForeignKey(valueType: String, key: String, type: String) {
        let row = minimalRow.replacingOccurrences(of: #"{"type": "bool"}"#, with: valueType)

        #expect(throws: CatalogError.malformed(path: "tweaks[0].valueType.\(key)", reason: #"Key "\#(key)" does not apply to type "\#(type)""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test func suggestionRejectsUnknownKey() {
        let row = minimalRow.replacingOccurrences(
            of: #""risks": []"#, with: #""risks": [], "suggestions": [{"value": "a", "label": "A", "hint": "x"}]"#)

        #expect(throws: CatalogError.malformed(path: "tweaks[0].suggestions[0].hint", reason: #"Unknown key "hint""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test func emptyListsAreLeftOutWhenEncoding() throws {
        let text = String(decoding: try JSONEncoder().encode(CatalogSamples.tweak("x")), as: UTF8.self)

        #expect(!text.contains("suggestions"))
        #expect(!text.contains("userOnlyValues"))
    }

    @Test func requiresRisks() {
        let row = minimalRow.replacingOccurrences(of: #""risks": [], "#, with: "")

        #expect(throws: CatalogError.malformed(path: "tweaks[0].risks", reason: #"Missing key "risks""#)) {
            try decode(catalogJSON(row: row))
        }
    }

    @Test func reportsInvalidJSON() throws {
        let error = try #require(throws: CatalogError.self) {
            try decode("{")
        }
        guard case .malformed(path: "", _) = error else {
            Issue.record("expected malformed at the root, got \(error)")
            return
        }
    }

    @Test(
        "tweak values decode by JSON kind",
        arguments: [
            ("true", TweakValue.bool(true)),
            ("false", .bool(false)),
            ("1", .integer(1)),
            ("0", .integer(0)),
            ("42", .integer(42)),
            ("-1", .integer(-1)),
            (#""fullscreen""#, .string("fullscreen")),
            (#""1""#, .string("1")),
        ])
    func decodesTweakValue(json: String, expected: TweakValue) throws {
        #expect(try JSONDecoder().decode(TweakValue.self, from: Data(json.utf8)) == expected)
    }

    @Test("tweak values reject other JSON kinds", arguments: ["1.5", "null", "[]", "{}"])
    func rejectsTweakValue(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TweakValue.self, from: Data(json.utf8))
        }
    }
}
