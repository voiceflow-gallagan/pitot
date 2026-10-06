import Foundation
import Testing

@testable import PitotCore

/// The rule engines on the settings a session gets from all layers. Each change is written to one
/// target layer; requirements, disabled rows and env overrides use the effective values after that write.
@Suite("Layered rules")
struct LayeredRulesTests {
    let catalog: Catalog

    init() throws {
        catalog = try CatalogSamples.catalog()
    }

    private func layers(_ layers: (LayerID, String)...) -> EffectiveSettings {
        EffectiveSettings(layers: layers.map { LayerLoader.layer(id: $0.0, url: nil, bytes: Array($0.1.utf8)) })
    }

    private func resolve(_ effective: EffectiveSettings, target: LayerID, _ changes: ProposedChange...) -> Resolution {
        Dependencies.resolve(catalog, effective: effective, changes: changes, target: target)
    }

    private func set(_ id: String, _ value: TweakValue?) -> ProposedChange {
        ProposedChange(tweakId: id, value: value)
    }

    private func tweak(_ id: String) throws -> Tweak {
        try #require(catalog.tweak(id: id))
    }

    // MARK: Reading

    @Test func readingNamesTheWinningLayerAndTheOverriddenOnes() throws {
        let effective = layers((.user, #"{"tui": "default"}"#), (.local, #"{"tui": "fullscreen"}"#))

        #expect(try tweak("tui").reading(in: effective) == LayeredReading(reading: .value("fullscreen"), winner: .local, overridden: [.user]))
        #expect(try tweak("viewMode").reading(in: effective) == LayeredReading(reading: .unset, winner: nil, overridden: []))
    }

    @Test func readingDecodesEnvRowsFromTheMergedEnv() throws {
        let effective = layers((.user, #"{"env": {"DISABLE_TELEMETRY": "1"}}"#), (.project, #"{"env": {"CLAUDE_CODE_NO_FLICKER": "0"}}"#))

        #expect(try tweak("disableTelemetry").reading(in: effective) == LayeredReading(reading: .value(true), winner: .user, overridden: []))
        #expect(try tweak("noFlicker").reading(in: effective) == LayeredReading(reading: .value(false), winner: .project, overridden: []))
    }

    // MARK: Shadowing

    @Test func localValueShadowsAChangeWrittenToUser() {
        let resolution = resolve(layers((.local, #"{"tui": "default"}"#)), target: .user, set("tui", "fullscreen"))

        #expect(resolution.shadowed == [Resolution.Shadowed(tweakId: "tui", by: .local, effective: .value("default"))])
        #expect(resolution.blocked.isEmpty)
    }

    @Test func changeWrittenToTheWinningLayerIsNotShadowed() {
        #expect(resolve(layers((.local, #"{"tui": "default"}"#)), target: .local, set("tui", "fullscreen")).shadowed.isEmpty)
    }

    @Test func removingAValueThatAHigherLayerAlsoSetsIsShadowed() {
        let effective = layers((.user, #"{"tui": "fullscreen"}"#), (.local, #"{"tui": "default"}"#))

        let resolution = resolve(effective, target: .user, set("tui", nil))

        #expect(resolution.shadowed == [Resolution.Shadowed(tweakId: "tui", by: .local, effective: .value("default"))])
    }

    @Test func removingFromAHigherLayerFallsBackToALowerOneWithoutShadowing() {
        let effective = layers((.user, #"{"tui": "fullscreen"}"#), (.project, #"{"tui": "default"}"#))

        #expect(resolve(effective, target: .project, set("tui", nil)).shadowed.isEmpty)
    }

    @Test func shadowedChangeTriggersNoRequirement() {
        let resolution = resolve(layers((.local, #"{"viewMode": "default"}"#)), target: .user, set("viewMode", "focus"))

        #expect(resolution.shadowed.map(\.tweakId) == ["viewMode"])
        #expect(resolution.autoSet.isEmpty)
    }

    // MARK: Managed and layer limits

    @Test func managedValueLocksTheRow() {
        let resolution = resolve(layers((.managed, #"{"tui": "fullscreen"}"#)), target: .user, set("tui", "default"))

        #expect(resolution.lockedByManaged == ["tui"])
        #expect(resolution.blocked == ["tui": "Set by your organization."])
    }

    @Test func managedTargetIsNeverWritable() {
        let resolution = resolve(layers(), target: .managed, set("tui", "default"))

        #expect(resolution.refusedInLayer.map(\.tweakId) == ["tui"])
        #expect(resolution.blocked["tui"] != nil)
    }

    @Test(arguments: [LayerID.project, .local])
    func userOnlyValueIsRefusedInSharedLayers(target: LayerID) {
        let resolution = resolve(layers(), target: target, set("permissions.defaultMode", "bypassPermissions"))

        #expect(resolution.refusedInLayer.map(\.tweakId) == ["permissions.defaultMode"])
        #expect(resolution.blocked["permissions.defaultMode"] != nil)
    }

    @Test func userOnlyValueIsAllowedInUser() {
        let resolution = resolve(layers(), target: .user, set("permissions.defaultMode", "bypassPermissions"))

        #expect(resolution.refusedInLayer.isEmpty)
        #expect(resolution.blocked.isEmpty)
    }

    @Test func otherValuesOfAUserOnlyValueRowAreAllowedInProject() {
        #expect(resolve(layers(), target: .project, set("permissions.defaultMode", "plan")).refusedInLayer.isEmpty)
    }

    @Test func userOnlyRowIsRefusedInLocal() {
        #expect(resolve(layers(), target: .local, set("askUserQuestionTimeout", "5m")).refusedInLayer.map(\.tweakId) == ["askUserQuestionTimeout"])
    }

    // MARK: Requirements on effective values

    @Test func focusInProjectAutoSetsFullscreenThereWhenUserLevelTuiIsClassic() {
        let resolution = resolve(layers((.user, #"{"tui": "default"}"#)), target: .project, set("viewMode", "focus"))

        #expect(resolution.autoSet == [Resolution.AutoSet(tweakId: "tui", value: "fullscreen", reason: "Focus view needs the fullscreen renderer.")])
        #expect(resolution.shadowed.isEmpty)
        #expect(resolution.warnings.isEmpty)
    }

    @Test func focusInProjectNeedsNoAutoSetWhenUserLevelTuiIsFullscreen() {
        #expect(resolve(layers((.user, #"{"tui": "fullscreen"}"#)), target: .project, set("viewMode", "focus")).autoSet.isEmpty)
    }

    @Test func autoSetInProjectShadowedByLocalTuiIsReported() {
        let resolution = resolve(layers((.local, #"{"tui": "default"}"#)), target: .project, set("viewMode", "focus"))

        #expect(resolution.autoSet.map(\.tweakId) == ["tui"])
        #expect(resolution.shadowed == [Resolution.Shadowed(tweakId: "tui", by: .local, effective: .value("default"))])
        #expect(resolution.warnings.contains { $0.hasPrefix("These changes conflict.") })
    }

    @Test func clearingTuiInLocalWhileFocusIsInEffectFromUserSuggestsClearingViewMode() {
        let effective = layers((.user, #"{"viewMode": "focus"}"#), (.local, #"{"tui": "fullscreen"}"#))

        let resolution = resolve(effective, target: .local, set("tui", nil))

        #expect(resolution.unsetSuggestions.map(\.tweakId) == ["viewMode"])
    }

    @Test func disabledRowsFollowTheEffectiveValue() {
        let onAtUser = layers((.user, #"{"sandbox": {"enabled": true}}"#))
        let offAtLocal = layers((.user, #"{"sandbox": {"enabled": true}}"#), (.local, #"{"sandbox": {"enabled": false}}"#))

        #expect(resolve(onAtUser, target: .project, set("sandbox.failIfUnavailable", true)).blocked.isEmpty)
        #expect(resolve(offAtLocal, target: .project, set("sandbox.failIfUnavailable", true)).blocked["sandbox.failIfUnavailable"] != nil)
    }

    // MARK: Env overrides across layers

    @Test func envOverrideFromAnotherLayerNamesThatLayer() {
        let resolution = resolve(layers((.project, #"{"env": {"CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"}}"#)), target: .user, set("tui", "fullscreen"))

        #expect(
            resolution.warnings == [
                "Renderer has no effect while CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 is set in the env block of the shared project settings."
            ])
    }

    @Test func changedEnvVarNamesTheTargetLayer() {
        let resolution = resolve(layers((.user, #"{"tui": "fullscreen"}"#)), target: .local, set("noFlicker", false))

        #expect(resolution.warnings == ["Renderer has no effect while CLAUDE_CODE_NO_FLICKER=0 is set in the env block of the local project settings."])
    }

    @Test func envVarRemovedFromOneLayerButSetInAnotherStillOverrides() {
        let effective = layers(
            (.user, #"{"tui": "fullscreen", "env": {"CLAUDE_CODE_NO_FLICKER": "0"}}"#), (.local, #"{"env": {"CLAUDE_CODE_NO_FLICKER": "0"}}"#))

        let resolution = resolve(effective, target: .local, set("noFlicker", nil))

        #expect(resolution.warnings == ["Renderer has no effect while CLAUDE_CODE_NO_FLICKER=0 is set in the env block of the user settings."])
    }

    // MARK: Confirmation

    @Test func turningSandboxOffInLocalWhileAUserLevelTrueIsInEffectConfirms() throws {
        let sandbox = try tweak("sandbox.enabled")
        let old = sandbox.reading(in: layers((.user, #"{"sandbox": {"enabled": true}}"#)))

        #expect(old.winner == .user)
        #expect(Tweak.Confirmation.isRequired(for: sandbox, old: old, new: false))
    }

    @Test func writingOffWhileTheEffectiveValueIsAlreadyOffDoesNotConfirm() throws {
        let sandbox = try tweak("sandbox.enabled")
        let old = sandbox.reading(in: layers((.user, #"{"sandbox": {"enabled": false}}"#)))

        #expect(!Tweak.Confirmation.isRequired(for: sandbox, old: old, new: false))
        #expect(!Tweak.Confirmation.isRequired(for: sandbox, old: sandbox.reading(in: layers()), new: false))
    }

    // MARK: Compatibility

    @Test func singleChangeOverloadMatchesTheGroupOne() {
        let effective = layers((.local, #"{"tui": "default"}"#))

        #expect(
            Dependencies.resolve(catalog, effective: effective, change: set("tui", "fullscreen"), target: .user)
                == resolve(effective, target: .user, set("tui", "fullscreen")))
    }

    @Test func oneUserLayerGivesTheSameRulesAsTheDocumentForm() throws {
        let text = #"{"viewMode": "focus", "tui": "fullscreen", "env": {"CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"}}"#
        let layered = resolve(layers((.user, text)), target: .user, set("tui", nil))
        let single = Dependencies.resolve(catalog, document: try CatalogSamples.document(text), change: set("tui", nil))

        #expect(layered.autoSet == single.autoSet)
        #expect(layered.disabled == single.disabled)
        #expect(layered.blocked == single.blocked)
        #expect(layered.unsetSuggestions == single.unsetSuggestions)
    }
}
