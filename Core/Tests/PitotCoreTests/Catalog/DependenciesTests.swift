import Foundation
import Testing

@testable import PitotCore

@Suite("Dependencies")
struct DependenciesTests {
    let catalog: Catalog

    init() throws {
        catalog = try CatalogSamples.catalog()
    }

    private func resolve(_ text: String, _ changes: ProposedChange...) throws -> Resolution {
        Dependencies.resolve(catalog, document: try CatalogSamples.document(text), changes: changes)
    }

    /// A flag that works only once a string row holds any value: a `requires` rule without `equals`.
    private func needsAnyValue(_ text: String, _ changes: ProposedChange...) throws -> Resolution {
        let requirement = Tweak.Requirement(tweakId: "helper", equals: nil, behavior: .disable, reason: "Set a helper first.")
        let catalog = CatalogSamples.catalog([
            CatalogSamples.tweak("helper", location: .env(name: "HELPER_COMMAND"), valueType: .string),
            CatalogSamples.tweak("helperStrict", location: .env(name: "HELPER_STRICT"), valueType: .flag, requires: [requirement]),
        ])
        return Dependencies.resolve(catalog, document: try CatalogSamples.document(text), changes: changes)
    }

    private func set(_ id: String, _ value: TweakValue?) -> ProposedChange {
        ProposedChange(tweakId: id, value: value)
    }

    private static func chain(length: Int) -> Catalog {
        CatalogSamples.catalog(
            (0..<length).map { index in
                let next = Tweak.Requirement(tweakId: "t\(index + 1)", equals: true, behavior: .autoSet, reason: "t\(index) needs t\(index + 1)")
                return CatalogSamples.tweak("t\(index)", requires: index + 1 < length ? [next] : [])
            })
    }

    // MARK: autoSet

    @Test func focusViewAutoSetsFullscreen() throws {
        let resolution = try resolve("{}", set("viewMode", "focus"))

        #expect(resolution.autoSet == [Resolution.AutoSet(tweakId: "tui", value: "fullscreen", reason: "Focus view needs the fullscreen renderer.")])
        #expect(resolution.warnings.isEmpty)
        #expect(resolution.blocked.isEmpty)
    }

    @Test func fullscreenAlreadySetNeedsNoAutoSet() throws {
        #expect(try resolve(#"{"tui": "fullscreen"}"#, set("viewMode", "focus")).autoSet.isEmpty)
    }

    @Test func otherViewsDoNotNeedFullscreen() throws {
        #expect(try resolve("{}", set("viewMode", "verbose")).autoSet.isEmpty)
    }

    @Test("turning tui off or to default while focus is set suggests clearing viewMode", arguments: [nil, TweakValue.string("default")])
    func leavingFullscreenWhileFocusWarns(value: TweakValue?) throws {
        let resolution = try resolve(#"{"viewMode": "focus", "tui": "fullscreen"}"#, set("tui", value))

        #expect(resolution.unsetSuggestions == [Resolution.UnsetSuggestion(tweakId: "viewMode", reason: "Focus view needs the fullscreen renderer.")])
        #expect(resolution.warnings.count == 1)
        #expect(resolution.warnings.first?.contains("Starting view needs Renderer set to fullscreen") == true)
        #expect(resolution.autoSet.isEmpty)
    }

    @Test func leavingFullscreenWithoutFocusIsQuiet() throws {
        let resolution = try resolve(#"{"viewMode": "verbose", "tui": "fullscreen"}"#, set("tui", nil))

        #expect(resolution.warnings.isEmpty)
        #expect(resolution.unsetSuggestions.isEmpty)
    }

    @Test func explicitChangeIsNeverOverwrittenByAutoSet() throws {
        let resolution = try resolve("{}", set("viewMode", "focus"), set("tui", "default"))

        #expect(resolution.autoSet.isEmpty)
        #expect(resolution.unsetSuggestions.isEmpty)
        #expect(resolution.warnings.count == 1)
        #expect(resolution.warnings.first?.hasPrefix("These changes conflict.") == true)
    }

    @Test func chainsResolveTransitively() throws {
        let resolution = Dependencies.resolve(Self.chain(length: 3), document: try CatalogSamples.document("{}"), change: set("t0", true))

        #expect(resolution.autoSet.map(\.tweakId) == ["t1", "t2"])
        #expect(resolution.autoSet.map(\.reason) == ["t0 needs t1", "t1 needs t2"])
        #expect(resolution.warnings.isEmpty)
    }

    @Test func chainStopsAtTheDepthGuard() throws {
        let catalog = Self.chain(length: Dependencies.maximumChainDepth + 4)

        let resolution = Dependencies.resolve(catalog, document: try CatalogSamples.document("{}"), change: set("t0", true))

        #expect(resolution.autoSet.count == Dependencies.maximumChainDepth)
        #expect(resolution.warnings.count == 1)
        #expect(resolution.warnings.first?.hasPrefix("Stopped following requirements") == true)
    }

    @Test func loopInDataIsRejectedByLintAndStillTerminates() throws {
        let a = CatalogSamples.tweak("a", requires: [Tweak.Requirement(tweakId: "b", equals: true, behavior: .autoSet, reason: "a needs b")])
        let b = CatalogSamples.tweak("b", requires: [Tweak.Requirement(tweakId: "c", equals: true, behavior: .autoSet, reason: "b needs c")])
        let c = CatalogSamples.tweak("c", requires: [Tweak.Requirement(tweakId: "a", equals: false, behavior: .autoSet, reason: "c needs a off")])
        let looping = CatalogSamples.catalog([a, b, c])

        #expect(CatalogLinter.lint(looping).map(\.rule) == [.requirementCycle])

        let resolution = Dependencies.resolve(looping, document: try CatalogSamples.document("{}"), change: set("a", true))

        #expect(resolution.autoSet.map(\.tweakId) == ["b", "c"])
        #expect(resolution.warnings.contains { $0.hasPrefix("These changes conflict.") })
    }

    @Test func autoSetLoopBetweenTwoRowsTerminates() throws {
        let a = CatalogSamples.tweak("a", requires: [Tweak.Requirement(tweakId: "b", equals: true, behavior: .autoSet, reason: "a needs b")])
        let b = CatalogSamples.tweak("b", requires: [Tweak.Requirement(tweakId: "a", equals: true, behavior: .autoSet, reason: "b needs a")])

        let resolution = Dependencies.resolve(CatalogSamples.catalog([a, b]), document: try CatalogSamples.document("{}"), change: set("a", true))

        #expect(resolution.autoSet.map(\.tweakId) == ["b"])
        #expect(resolution.warnings.isEmpty)
    }

    @Test func duplicateIdsInDataDoNotCrash() throws {
        let catalog = CatalogSamples.catalog([CatalogSamples.tweak("a"), CatalogSamples.tweak("a")])

        let resolution = Dependencies.resolve(catalog, document: try CatalogSamples.document("{}"), change: set("a", true))

        #expect(resolution.blocked.isEmpty)
    }

    // MARK: disable

    @Test func rowIsDisabledUntilItsTargetHasAnyValue() throws {
        let reason = "Set a helper first."

        #expect(try needsAnyValue("{}", set("helper", nil)).disabled["helperStrict"] == reason)
        #expect(try needsAnyValue("{}", set("helperStrict", true)).blocked == ["helperStrict": reason])
        #expect(try needsAnyValue("{}", set("helper", "run.sh")).disabled["helperStrict"] == nil)
        #expect(try needsAnyValue("{}", set("helper", "run.sh"), set("helperStrict", true)).blocked.isEmpty)
        #expect(try needsAnyValue(#"{"env": {"HELPER_COMMAND": "run.sh"}}"#, set("helperStrict", true)).blocked.isEmpty)
    }

    @Test func turningADisabledFlagOffIsNeverBlocked() throws {
        let resolution = try needsAnyValue(#"{"env": {"HELPER_STRICT": "1"}}"#, set("helperStrict", false))

        #expect(resolution.blocked.isEmpty)
        #expect(resolution.disabled["helperStrict"] != nil)
    }

    @Test func clearingTheTargetSuggestsClearingTheDependent() throws {
        let resolution = try needsAnyValue(#"{"env": {"HELPER_COMMAND": "run.sh", "HELPER_STRICT": "1"}}"#, set("helper", nil))

        #expect(resolution.disabled["helperStrict"] == "Set a helper first.")
        #expect(resolution.unsetSuggestions.map(\.tweakId) == ["helperStrict"])
    }

    @Test func subagentModelForceWorksWithoutASubagentModel() throws {
        let resolution = try resolve("{}", set("subagentModelForce", true))

        #expect(resolution.blocked.isEmpty)
        #expect(resolution.disabled["subagentModelForce"] == nil)
    }

    @Test("sandbox sub-options are disabled while sandbox.enabled is not true", arguments: ["{}", #"{"sandbox": {"enabled": false}}"#])
    func sandboxSubOptionsDisabled(text: String) throws {
        let disabled = Dependencies.disabledReasons(catalog, document: try CatalogSamples.document(text))

        #expect(disabled["sandbox.failIfUnavailable"] == "Only matters while the sandbox is on.")
        #expect(disabled["sandbox.autoAllowBashIfSandboxed"] == "Only matters while the sandbox is on.")
    }

    @Test func enablingSandboxEnablesSubOptions() throws {
        let resolution = try resolve("{}", set("sandbox.enabled", true), set("sandbox.failIfUnavailable", true))

        #expect(resolution.disabled["sandbox.failIfUnavailable"] == nil)
        #expect(resolution.disabled["sandbox.autoAllowBashIfSandboxed"] == nil)
        #expect(resolution.blocked.isEmpty)
    }

    @Test func turningSandboxOffLeavesSubOptionWithoutEffect() throws {
        let resolution = try resolve(#"{"sandbox": {"enabled": true, "failIfUnavailable": true}}"#, set("sandbox.enabled", false))

        #expect(resolution.disabled.keys.sorted() == ["sandbox.autoAllowBashIfSandboxed", "sandbox.failIfUnavailable"])
        #expect(resolution.unsetSuggestions.map(\.tweakId) == ["sandbox.failIfUnavailable"])
    }

    @Test func fixedStringIsOnOnlyWithItsValue() throws {
        let fixed = CatalogSamples.tweak("fixed", valueType: .fixedString("disable"))
        let reason = "Turn fixed on first."
        let dependent = CatalogSamples.tweak("dependent", requires: [Tweak.Requirement(tweakId: "fixed", equals: true, behavior: .disable, reason: reason)])
        let catalog = CatalogSamples.catalog([fixed, dependent])

        #expect(Dependencies.disabledReasons(catalog, document: try CatalogSamples.document(#"{"fixed": "disable"}"#)).isEmpty)
        #expect(Dependencies.disabledReasons(catalog, document: try CatalogSamples.document(#"{"fixed": "other"}"#)) == ["dependent": reason])
        #expect(Dependencies.disabledReasons(catalog, document: try CatalogSamples.document("{}")) == ["dependent": reason])
    }

    @Test func unknownTweakIsBlocked() throws {
        #expect(try resolve("{}", set("nope", true)).blocked == ["nope": "This setting is not in the catalog."])
    }

    // MARK: env overrides

    @Test func disableAlternateScreenBeatsTui() throws {
        let resolution = try resolve(#"{"env": {"CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"}}"#, set("tui", "fullscreen"))

        #expect(resolution.warnings == ["Renderer has no effect while CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 is set in the env block of this file."])
    }

    @Test func overrideIsReportedForAnAutoSetTarget() throws {
        let resolution = try resolve(#"{"env": {"CLAUDE_CODE_NO_FLICKER": "0"}}"#, set("viewMode", "focus"))

        #expect(resolution.autoSet.map(\.tweakId) == ["tui"])
        #expect(resolution.warnings == ["Renderer has no effect while CLAUDE_CODE_NO_FLICKER=0 is set in the env block of this file."])
    }

    @Test func effortEnvBeatsEffortLevel() throws {
        let resolution = try resolve(#"{"env": {"CLAUDE_CODE_EFFORT_LEVEL": "max"}}"#, set("effortLevel", "low"))

        #expect(resolution.warnings == ["Effort has no effect while CLAUDE_CODE_EFFORT_LEVEL=max is set in the env block of this file."])
    }

    @Test func anthropicModelBeatsModel() throws {
        let resolution = try resolve(#"{"env": {"ANTHROPIC_MODEL": "haiku"}}"#, set("model", "opus"))

        #expect(resolution.warnings == ["Model has no effect while ANTHROPIC_MODEL=haiku is set in the env block of this file."])
    }

    @Test("connector env override applies only when it turns connectors off", arguments: [("false", true), ("0", true), ("true", false), ("", false)])
    func connectorOverrideMatchesValue(envValue: String, warns: Bool) throws {
        let resolution = try resolve(#"{"env": {"ENABLE_CLAUDEAI_MCP_SERVERS": "\#(envValue)"}}"#, set("disableClaudeAiConnectors", false))

        #expect(!resolution.warnings.isEmpty == warns)
    }

    @Test func changingTheEnvVarWarnsAboutTheSettingItBeats() throws {
        let resolution = try resolve(#"{"tui": "fullscreen"}"#, set("noFlicker", false))

        #expect(resolution.warnings == ["Renderer has no effect while CLAUDE_CODE_NO_FLICKER=0 is set in the env block of this file."])
    }

    @Test func removingTheEnvVarClearsTheWarning() throws {
        let resolution = try resolve(#"{"tui": "fullscreen", "env": {"CLAUDE_CODE_NO_FLICKER": "0"}}"#, set("noFlicker", nil))

        #expect(resolution.warnings.isEmpty)
    }

    @Test func unsettingAnOverriddenSettingDoesNotWarn() throws {
        #expect(try resolve(#"{"model": "opus", "env": {"ANTHROPIC_MODEL": "haiku"}}"#, set("model", nil)).warnings.isEmpty)
    }

    @Test func unrelatedChangeDoesNotRepeatOverrideWarnings() throws {
        #expect(try resolve(#"{"model": "opus", "env": {"ANTHROPIC_MODEL": "haiku"}}"#, set("tui", "default")).warnings.isEmpty)
    }
}
