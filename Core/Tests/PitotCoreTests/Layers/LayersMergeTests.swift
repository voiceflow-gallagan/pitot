import Foundation
import Testing

@testable import PitotCore

/// Inline fixtures follow the test runs behind `Core/MERGE-RULES.md`. Rule numbers refer to that file.
@Suite("Layers: merge rules")
struct LayersMergeTests {
    private typealias Contribution = EffectiveValue.Contribution

    @Test func localBeatsProjectBeatsUser() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"outputStyle": "User"}"#),
            (.project, #"{"outputStyle": "Explanatory"}"#),
            (.local, #"{"outputStyle": "Learning"}"#)
        )
        let effective = try #require(settings.value(at: ["outputStyle"]))

        #expect(effective.value == "Learning")
        #expect(effective.winner == .local)
        #expect(effective.contributions == [
            Contribution(layer: .local, value: "Learning"),
            Contribution(layer: .project, value: "Explanatory"),
            Contribution(layer: .user, value: "User"),
        ])
        #expect(effective.overriddenLayers == [.project, .user])
        #expect(effective.ignoredLayers.isEmpty)
        #expect(effective.merged == false)
    }

    @Test func managedBeatsEveryOtherLayer() throws {
        let settings = LayersFixtures.settings(
            (.managed, #"{"model": "managed"}"#),
            (.local, #"{"model": "local"}"#),
            (.user, #"{"model": "user"}"#)
        )
        let effective = try #require(settings.value(at: ["model"]))

        #expect(effective.value == "managed")
        #expect(effective.winner == .managed)
        #expect(effective.overriddenLayers == [.local, .user])
    }

    @Test func layerOrderPassedInDoesNotMatter() {
        let layers = [
            LayersFixtures.layer(.local, #"{"model": "local"}"#),
            LayersFixtures.layer(.user, #"{"model": "user"}"#),
            LayersFixtures.layer(.project, #"{"model": "project"}"#),
        ]
        let settings = EffectiveSettings(layers: layers)

        #expect(settings.value(at: ["model"])?.winner == .local)
        #expect(settings.layers.map(\.id) == [.local, .project, .user])
        #expect(EffectiveSettings(layers: layers.reversed()).merged == settings.merged)
    }

    @Test func unsetKeyHasNoEffectiveValue() {
        let settings = LayersFixtures.settings((.user, #"{"model": "opus"}"#))
        #expect(settings.value(at: ["outputStyle"]) == nil)
        #expect(EffectiveSettings(layers: []).value(at: ["model"]) == nil)
    }

    @Test func missingInvalidAndUnreadableLayersContributeNothing() throws {
        let settings = EffectiveSettings(layers: [
            LayersFixtures.layer(.user, #"{"model": "user"}"#),
            SettingsLayer(id: .project, url: nil, state: .missing),
            LayersFixtures.layer(.local, #"{"model": "local""#),
            SettingsLayer(id: .managed, url: nil, state: .unreadable("denied")),
        ])
        let effective = try #require(settings.value(at: ["model"]))

        #expect(effective.value == "user")
        #expect(effective.contributions == [Contribution(layer: .user, value: "user")])
        #expect(settings.layer(.local).map(LayersFixtures.problem(of:)) != nil)
        #expect(settings.layer(.managed)?.state == .unreadable("denied"))
    }

    /// Rules 8 and 9 (tested, run 3): a typed key set to null drops the whole file.
    @Test func nullAtATypedKeyDropsTheWholeFile() throws {
        let settings = LayersFixtures.settings(
            (.project, #"{"outputStyle": "Explanatory", "permissions": {"defaultMode": "acceptEdits"}, "env": {"PITOT_TEST_R3": "project"}}"#),
            (.local, #"{"outputStyle": null, "env": {"PITOT_TEST_R3": null, "R3_LOCAL": "local"}}"#)
        )

        #expect(settings.value(at: ["outputStyle"])?.value == "Explanatory")
        #expect(settings.value(at: ["env", "PITOT_TEST_R3"])?.value == "project")
        #expect(settings.value(at: ["env", "R3_LOCAL"]) == nil)
        #expect(settings.value(at: ["permissions", "defaultMode"])?.winner == .project)
    }

    /// Rule 7 (tested, runs 2 and 4): a null env variable wins and processes see the text `null`.
    @Test func nullEnvVariableWinsAsTheTextNull() throws {
        let settings = LayersFixtures.settings(
            (.project, #"{"env": {"PITOT_TEST_R3": "project"}}"#),
            (.local, #"{"env": {"PITOT_TEST_R3": null, "R3_LOCAL": "local"}}"#)
        )
        let effective = try #require(settings.value(at: ["env", "PITOT_TEST_R3"]))

        #expect(effective.value == "null")
        #expect(effective.winner == .local)
        #expect(effective.contributions.first == Contribution(layer: .local, value: .null))
        #expect(effective.overriddenLayers == [.project])
        #expect(settings.value(at: ["env"])?.value == ["PITOT_TEST_R3": "null", "R3_LOCAL": "local"])
    }

    /// Rules 2, 3 and 6 (tested, run 1): env merges per variable, the highest layer wins each one.
    @Test func envMergesPerVariable() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"env": {"ONLY_USER": "user", "SHARED": "user"}}"#),
            (.project, #"{"env": {"ONLY_PROJECT": "project", "SHARED": "project"}}"#),
            (.local, #"{"env": {"ONLY_LOCAL": "local", "SHARED": "local"}}"#)
        )

        #expect(settings.value(at: ["env", "ONLY_USER"])?.winner == .user)
        #expect(settings.value(at: ["env", "ONLY_PROJECT"])?.winner == .project)
        #expect(settings.value(at: ["env", "ONLY_LOCAL"])?.value == "local")
        let shared = try #require(settings.value(at: ["env", "SHARED"]))
        #expect(shared.value == "local")
        #expect(shared.overriddenLayers == [.project, .user])

        let env = try #require(settings.value(at: ["env"]))
        #expect(env.value == ["ONLY_USER": "user", "SHARED": "local", "ONLY_PROJECT": "project", "ONLY_LOCAL": "local"])
        #expect(env.merged)
        #expect(env.winner == .local)
        #expect(env.overriddenLayers.isEmpty)
    }

    /// Rule 5 (tested, run 2): an empty env object in a higher layer erases nothing.
    @Test func emptyEnvErasesNothing() {
        let settings = LayersFixtures.settings(
            (.project, #"{"env": {"KEEP_A": "project"}}"#),
            (.local, #"{"env": {}}"#)
        )
        #expect(settings.value(at: ["env", "KEEP_A"])?.value == "project")
    }

    /// Rules 11 and 14 (tested, run 1): nested objects merge key by key, lists join.
    @Test func nestedObjectsMergeAndListsJoin() throws {
        let settings = LayersFixtures.settings(
            (.project, #"{"permissions": {"defaultMode": "acceptEdits", "allow": ["Bash(ls)"]}}"#),
            (.local, #"{"permissions": {"allow": ["Read"]}}"#)
        )

        #expect(settings.value(at: ["permissions", "defaultMode"])?.value == "acceptEdits")
        let allow = try #require(settings.value(at: ["permissions", "allow"]))
        #expect(allow.value == ["Bash(ls)", "Read"])
        #expect(allow.merged)
        #expect(allow.winner == .local)
        #expect(allow.overriddenLayers.isEmpty)
        #expect(allow.contributions.map(\.layer) == [.local, .project])
    }

    /// Rule 18 (inferred): lists join lowest first and repeated strings, numbers and Booleans are removed.
    @Test func listsJoinLowestFirstWithoutDuplicates() {
        let settings = LayersFixtures.settings(
            (.user, #"{"permissions": {"allow": ["a", "b"]}, "numbers": [1, 2]}"#),
            (.project, #"{"permissions": {"allow": ["b", "c"]}, "numbers": [2.0, 3]}"#),
            (.local, #"{"permissions": {"allow": ["c", "d", "a"]}}"#)
        )

        #expect(settings.value(at: ["permissions", "allow"])?.value == ["a", "b", "c", "d"])
        #expect(settings.value(at: ["numbers"])?.value == [1, 2, 3])
    }

    /// One file alone is copied as it is; duplicates go only when two files join.
    @Test func singleListKeepsItsOwnRepeats() {
        let settings = LayersFixtures.settings((.user, #"{"permissions": {"allow": ["a", "a"]}}"#))
        #expect(settings.value(at: ["permissions", "allow"])?.value == ["a", "a"])
    }

    /// Rules 12 and 18: hook entries are objects, so the same entry from two files stays twice.
    @Test func hookEntriesFromTwoFilesBothStay() throws {
        let hook = #"{"hooks": [{"type": "command", "command": "echo hi"}]}"#
        let settings = LayersFixtures.settings(
            (.user, #"{"hooks": {"SessionStart": [\#(hook)], "UserPromptSubmit": [\#(hook)]}}"#),
            (.project, #"{"hooks": {"SessionStart": [\#(hook)]}}"#)
        )

        guard case .array(let entries)? = settings.value(at: ["hooks", "SessionStart"])?.value else {
            Issue.record("expected an array")
            return
        }
        #expect(entries.count == 2)
        #expect(settings.value(at: ["hooks", "UserPromptSubmit"])?.winner == .user)
    }

    @Test func higherObjectNeverRemovesLowerKeys() {
        let settings = LayersFixtures.settings(
            (.user, #"{"sandbox": {"enabled": true, "network": {"allowedDomains": ["a.com"]}}}"#),
            (.project, #"{"sandbox": {"network": {"allowedDomains": ["b.com"]}}}"#)
        )

        #expect(settings.value(at: ["sandbox", "enabled"])?.winner == .user)
        #expect(settings.value(at: ["sandbox", "network", "allowedDomains"])?.value == ["a.com", "b.com"])
    }

    /// Schema checks are not modeled, so an unknown key shows how a change of type merges.
    @Test func changeOfTypeReplacesTheLowerValue() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"custom": {"a": 1}}"#),
            (.project, #"{"custom": 5}"#)
        )

        #expect(settings.value(at: ["custom", "a"]) == nil)
        let custom = try #require(settings.value(at: ["custom"]))
        #expect(custom.value == 5)
        #expect(custom.overriddenLayers == [.user])

        let restored = LayersFixtures.settings(
            (.user, #"{"custom": {"a": 1}}"#),
            (.project, #"{"custom": 5}"#),
            (.local, #"{"custom": {"b": 2}}"#)
        )
        #expect(restored.value(at: ["custom"])?.value == ["b": 2])
        #expect(restored.value(at: ["custom", "a"]) == nil)
    }

    /// Rule 19: `fallbackModel` is an ordered chain, taken whole from the highest layer.
    @Test func fallbackModelTakesTheHighestListWhole() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"fallbackModel": ["sonnet", "haiku"]}"#),
            (.project, #"{"fallbackModel": ["opus"]}"#)
        )
        let effective = try #require(settings.value(at: ["fallbackModel"]))

        #expect(effective.value == ["opus"])
        #expect(effective.winner == .project)
        #expect(effective.overriddenLayers == [.user])
        #expect(effective.merged == false)
    }

    /// Rule 19: `modelPicker` is read from managed and user only, and taken whole.
    @Test func modelPickerIsIgnoredInProjectAndLocal() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"modelPicker": {"options": [{"model": "user"}]}}"#),
            (.local, #"{"modelPicker": {"options": [{"model": "local"}]}}"#)
        )
        let picker = try #require(settings.value(at: ["modelPicker"]))

        #expect(picker.value == ["options": [["model": "user"]]])
        #expect(picker.winner == .user)
        #expect(picker.ignoredLayers == [.local])
        #expect(picker.overriddenLayers == [.local])
        #expect(LayersFixtures.settings((.project, #"{"modelPicker": {"options": []}}"#)).value(at: ["modelPicker"]) == nil)
    }

    @Test func modelPickerFromManagedReplacesTheUserLineupWhole() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"modelPicker": {"options": [{"model": "user"}], "replaceBuiltInOptions": true}}"#),
            (.managed, #"{"modelPicker": {"options": [{"model": "managed"}]}}"#)
        )

        #expect(settings.value(at: ["modelPicker", "replaceBuiltInOptions"]) == nil)
        let options = try #require(settings.value(at: ["modelPicker", "options"]))
        #expect(options.value == [["model": "managed"]])
        #expect(options.winner == .managed)
        #expect(options.overriddenLayers == [.user])
    }

    /// Rule 21: a managed `availableModels` applies as is; otherwise lists join as usual.
    @Test func availableModelsFromManagedApplyAsIs() throws {
        let withManaged = LayersFixtures.settings(
            (.user, #"{"availableModels": ["sonnet"]}"#),
            (.project, #"{"availableModels": ["haiku"]}"#),
            (.managed, #"{"availableModels": ["opus"]}"#)
        )
        let managed = try #require(withManaged.value(at: ["availableModels"]))
        #expect(managed.value == ["opus"])
        #expect(managed.winner == .managed)
        #expect(managed.overriddenLayers == [.project, .user])

        let withoutManaged = LayersFixtures.settings(
            (.user, #"{"availableModels": ["sonnet"]}"#),
            (.project, #"{"availableModels": ["haiku"]}"#)
        )
        #expect(withoutManaged.value(at: ["availableModels"])?.value == ["sonnet", "haiku"])
        #expect(withoutManaged.value(at: ["availableModels"])?.merged == true)
    }

    /// Rule 21: `deniedModels` is read only from managed settings.
    @Test func deniedModelsComeOnlyFromManaged() throws {
        #expect(LayersFixtures.settings((.user, #"{"deniedModels": ["opus"]}"#)).value(at: ["deniedModels"]) == nil)

        let settings = LayersFixtures.settings(
            (.user, #"{"deniedModels": ["opus"]}"#),
            (.managed, #"{"deniedModels": ["haiku"]}"#)
        )
        let denied = try #require(settings.value(at: ["deniedModels"]))
        #expect(denied.value == ["haiku"])
        #expect(denied.ignoredLayers == [.user])
        #expect(settings.merged == ["deniedModels": ["haiku"]])
    }

    /// Rule 20: each marketplace entry comes whole from the highest layer that names it.
    @Test func marketplaceEntriesAreTakenWhole() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"extraKnownMarketplaces": {"team": {"source": "user", "autoUpdate": true}, "other": {"source": "o"}}}"#),
            (.project, #"{"extraKnownMarketplaces": {"team": {"source": "project"}}}"#)
        )

        #expect(settings.value(at: ["extraKnownMarketplaces", "team"])?.value == ["source": "project"])
        #expect(settings.value(at: ["extraKnownMarketplaces", "team", "autoUpdate"]) == nil)
        #expect(settings.value(at: ["extraKnownMarketplaces", "team", "source"])?.overriddenLayers == [.user])
        #expect(settings.value(at: ["extraKnownMarketplaces", "other"])?.winner == .user)
        let all = try #require(settings.value(at: ["extraKnownMarketplaces"]))
        #expect(all.merged)
    }

    /// `modelSettings` resolves one model at a time; Claude Code merges it deeply (inferred), so each field
    /// comes from the highest layer that sets it.
    @Test func modelSettingsResolvePerModel() {
        let settings = LayersFixtures.settings(
            (.user, #"{"modelSettings": {"opus": {"effortLevel": "high"}, "sonnet": {"effortLevel": "low"}}}"#),
            (.managed, #"{"modelSettings": {"opus": {"effortLevel": "medium"}}}"#)
        )

        #expect(settings.value(at: ["modelSettings", "opus", "effortLevel"])?.value == "medium")
        #expect(settings.value(at: ["modelSettings", "opus", "effortLevel"])?.winner == .managed)
        #expect(settings.value(at: ["modelSettings", "sonnet", "effortLevel"])?.winner == .user)
    }

    @Test func tweakLocationsReadSettingsAndEnv() throws {
        let sandbox = LayersFixtures.tweak("sandbox.enabled", .setting(path: ["sandbox", "enabled"]), .bool)
        let telemetry = LayersFixtures.tweak("DISABLE_TELEMETRY", .env(name: "DISABLE_TELEMETRY"), .flag)
        let settings = LayersFixtures.settings(
            (.user, #"{"sandbox": {"enabled": false}, "env": {"DISABLE_TELEMETRY": "1"}}"#),
            (.local, #"{"sandbox": {"enabled": true}}"#)
        )

        #expect(settings.value(for: sandbox)?.value == true)
        #expect(settings.value(for: sandbox)?.winner == .local)
        #expect(settings.value(for: telemetry)?.value == "1")
        #expect(settings.value(for: telemetry)?.winner == .user)
    }

    @Test func mergedHoldsTheWholeEffectiveSettings() {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "user", "env": {"A": "user"}, "permissions": {"allow": ["a"]}}"#),
            (.project, #"{"env": {"B": "project"}, "permissions": {"allow": ["b"]}}"#),
            (.local, #"{"model": "local", "env": {"A": null}}"#)
        )

        #expect(settings.merged == [
            "model": "local",
            "env": ["A": "null", "B": "project"],
            "permissions": ["allow": ["a", "b"]],
        ])
        #expect(settings.value(at: [])?.merged == true)
    }
}
