import Foundation
import Testing

@testable import PitotCore

/// The docs table "Exceptions to managed settings precedence" and the managed lock.
@Suite("Layers: restrictive keys and managed lock")
struct LayersRestrictiveTests {
    @Test func tableHasEveryRowOfTheDocsTable() {
        #expect(RestrictiveKey.all.map(\.path) == [
            ["disableClaudeAiConnectors"], ["enableArtifact"], ["disableArtifact"], ["isolatePeerMachines"],
            ["remoteControlAtStartup"], ["crossSessionInbound"], ["useAutoModeDuringPlan"], ["syncClaudeAiSkills"],
            ["syncClaudeAiPlugins"], ["maxEffortLevel"],
            ["permissions", "blockWritesOutsideWorkingDirectories"], ["permissions", "denyInsteadOfPrompting"],
            ["env", "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"],
        ])
        for key in RestrictiveKey.all {
            #expect(!key.quote.isEmpty)
            #expect(key.ladder.count >= 2)
        }
        #expect(RestrictiveKey.docURL.hasSuffix("settings#exceptions-to-managed-settings-precedence"))
        #expect(RestrictiveKey.rule(for: ["maxEffortLevel"])?.path == ["maxEffortLevel"])
        #expect(RestrictiveKey.rule(for: ["model"]) == nil)
    }

    @Test func connectorsOffFromAnyLayerBeatsManaged() throws {
        let settings = LayersFixtures.settings(
            (.managed, #"{"disableClaudeAiConnectors": false}"#),
            (.project, #"{"disableClaudeAiConnectors": true}"#)
        )
        let effective = try #require(settings.value(at: ["disableClaudeAiConnectors"]))

        #expect(effective.value == true)
        #expect(effective.winner == .project)
        #expect(effective.overriddenLayers == [.managed])
        #expect(settings.merged == ["disableClaudeAiConnectors": true])
    }

    @Test func projectFalseCannotUndoUserTrue() {
        let settings = LayersFixtures.settings(
            (.user, #"{"disableClaudeAiConnectors": true}"#),
            (.project, #"{"disableClaudeAiConnectors": false}"#)
        )
        #expect(settings.value(at: ["disableClaudeAiConnectors"])?.winner == .user)
        #expect(settings.value(at: ["disableClaudeAiConnectors"])?.overriddenLayers == [.project])
    }

    @Test func artifactAndPeerIsolationHonorTheirRestrictiveValue() {
        let settings = LayersFixtures.settings(
            (.managed, #"{"enableArtifact": true, "disableArtifact": false, "isolatePeerMachines": false}"#),
            (.user, #"{"enableArtifact": false, "disableArtifact": true, "isolatePeerMachines": true}"#)
        )

        #expect(settings.value(at: ["enableArtifact"])?.value == false)
        #expect(settings.value(at: ["disableArtifact"])?.value == true)
        #expect(settings.value(at: ["isolatePeerMachines"])?.winner == .user)
    }

    @Test func remoteControlOffFromProjectOrLocalBeatsManaged() throws {
        let local = LayersFixtures.settings(
            (.managed, #"{"remoteControlAtStartup": true}"#),
            (.local, #"{"remoteControlAtStartup": false}"#)
        )
        #expect(local.value(at: ["remoteControlAtStartup"])?.winner == .local)
        #expect(local.value(at: ["remoteControlAtStartup"])?.value == false)

        let user = LayersFixtures.settings(
            (.managed, #"{"remoteControlAtStartup": true}"#),
            (.user, #"{"remoteControlAtStartup": false}"#)
        )
        #expect(user.value(at: ["remoteControlAtStartup"])?.winner == .managed)
    }

    @Test func remoteControlOnFromProjectOrLocalIsIgnored() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"remoteControlAtStartup": false}"#),
            (.local, #"{"remoteControlAtStartup": true}"#)
        )
        let effective = try #require(settings.value(at: ["remoteControlAtStartup"]))

        #expect(effective.value == false)
        #expect(effective.winner == .user)
        #expect(effective.ignoredLayers == [.local])
        #expect(LayersFixtures.settings((.project, #"{"remoteControlAtStartup": true}"#)).value(at: ["remoteControlAtStartup"]) == nil)
    }

    @Test func crossSessionInboundTakesAStricterProjectOrLocalValue() throws {
        let stricter = LayersFixtures.settings(
            (.managed, #"{"crossSessionInbound": "hold"}"#),
            (.project, #"{"crossSessionInbound": "refuse"}"#)
        )
        #expect(stricter.value(at: ["crossSessionInbound"])?.value == "refuse")
        #expect(stricter.value(at: ["crossSessionInbound"])?.winner == .project)

        let looser = LayersFixtures.settings(
            (.managed, #"{"crossSessionInbound": "refuse"}"#),
            (.local, #"{"crossSessionInbound": "hold"}"#)
        )
        let effective = try #require(looser.value(at: ["crossSessionInbound"]))
        #expect(effective.value == "refuse")
        #expect(effective.overriddenLayers == [.local])
        #expect(effective.ignoredLayers.isEmpty)

        let notTightening = LayersFixtures.settings(
            (.user, #"{"crossSessionInbound": "hold"}"#),
            (.local, #"{"crossSessionInbound": "accept"}"#)
        )
        #expect(notTightening.value(at: ["crossSessionInbound"])?.value == "hold")
        #expect(notTightening.value(at: ["crossSessionInbound"])?.ignoredLayers == [.local])
        #expect(LayersFixtures.settings((.local, #"{"crossSessionInbound": "accept"}"#)).value(at: ["crossSessionInbound"]) == nil)
    }

    @Test func autoModeAndSyncOffFromManagedUserOrLocalButNotProject() {
        for key in ["useAutoModeDuringPlan", "syncClaudeAiSkills", "syncClaudeAiPlugins"] {
            let honored = LayersFixtures.settings(
                (.managed, #"{"\#(key)": true}"#),
                (.local, #"{"\#(key)": false}"#)
            )
            #expect(honored.value(at: [key])?.value == false)
            #expect(honored.value(at: [key])?.winner == .local)

            let project = LayersFixtures.settings(
                (.managed, #"{"\#(key)": true}"#),
                (.project, #"{"\#(key)": false}"#)
            )
            #expect(project.value(at: [key])?.value == true)
            #expect(project.value(at: [key])?.ignoredLayers == [.project])
        }
    }

    @Test func lowestEffortCapApplies() throws {
        let settings = LayersFixtures.settings(
            (.managed, #"{"maxEffortLevel": "high"}"#),
            (.user, #"{"maxEffortLevel": "medium"}"#),
            (.project, #"{"maxEffortLevel": "low"}"#)
        )
        let effective = try #require(settings.value(at: ["maxEffortLevel"]))
        #expect(effective.value == "low")
        #expect(effective.winner == .project)
        #expect(effective.overriddenLayers == [.managed, .user])

        let noCap = LayersFixtures.settings(
            (.managed, #"{"maxEffortLevel": "high"}"#),
            (.user, #"{"maxEffortLevel": "max"}"#)
        )
        #expect(noCap.value(at: ["maxEffortLevel"])?.value == "high")
    }

    @Test func writeBlockTrueFromAnyLayerApplies() throws {
        let path = ["permissions", "blockWritesOutsideWorkingDirectories"]
        let repo = LayersFixtures.settings(
            (.user, #"{"permissions": {"blockWritesOutsideWorkingDirectories": true}}"#),
            (.project, #"{"permissions": {"blockWritesOutsideWorkingDirectories": false}}"#)
        )
        let effective = try #require(repo.value(at: path))
        #expect(effective.value == true)
        #expect(effective.winner == .user)
        #expect(effective.overriddenLayers == [.project])
        #expect(repo.merged == ["permissions": ["blockWritesOutsideWorkingDirectories": true]])

        let managedFalse = LayersFixtures.settings(
            (.managed, #"{"permissions": {"blockWritesOutsideWorkingDirectories": false}}"#),
            (.user, #"{"permissions": {"blockWritesOutsideWorkingDirectories": true}}"#)
        )
        #expect(managedFalse.value(at: path)?.value == true)
        #expect(!managedFalse.lockedByManaged(path))
        #expect(LayersFixtures.settings((.managed, #"{"permissions": {"blockWritesOutsideWorkingDirectories": true}}"#)).lockedByManaged(path))
    }

    @Test func denyInsteadOfPromptingComesFromUserOrManagedAndTrueWins() throws {
        let path = ["permissions", "denyInsteadOfPrompting"]
        let repo = LayersFixtures.settings(
            (.user, #"{"permissions": {"denyInsteadOfPrompting": true}}"#),
            (.project, #"{"permissions": {"denyInsteadOfPrompting": false}}"#)
        )
        let effective = try #require(repo.value(at: path))
        #expect(effective.value == true)
        #expect(effective.winner == .user)
        #expect(effective.ignoredLayers == [.project])
        #expect(repo.merged == ["permissions": ["denyInsteadOfPrompting": true]])

        let local = LayersFixtures.settings(
            (.user, #"{"permissions": {"denyInsteadOfPrompting": false}}"#),
            (.local, #"{"permissions": {"denyInsteadOfPrompting": true}}"#)
        )
        #expect(local.value(at: path)?.value == false)
        #expect(local.value(at: path)?.ignoredLayers == [.local])

        let managedFalse = LayersFixtures.settings(
            (.managed, #"{"permissions": {"denyInsteadOfPrompting": false}}"#),
            (.user, #"{"permissions": {"denyInsteadOfPrompting": true}}"#)
        )
        #expect(managedFalse.value(at: path)?.value == true)
        #expect(!managedFalse.lockedByManaged(path))
        #expect(LayersFixtures.settings((.managed, #"{"permissions": {"denyInsteadOfPrompting": true}}"#)).lockedByManaged(path))
    }

    @Test func codeModeZeroFromUserOrManagedKeepsItOff() throws {
        let path = ["env", "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"]
        let userOff = LayersFixtures.settings(
            (.managed, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"}}"#),
            (.user, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "0"}}"#)
        )
        let effective = try #require(userOff.value(at: path))
        #expect(effective.value == "0")
        #expect(effective.winner == .user)
        #expect(effective.ignoredLayers == [.managed])
        #expect(!userOff.lockedByManaged(path))
        #expect(userOff.merged == ["env": ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "0"]])

        let managedOff = LayersFixtures.settings(
            (.managed, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "0"}}"#),
            (.user, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"}}"#)
        )
        #expect(managedOff.value(at: path)?.value == "0")
        #expect(managedOff.value(at: path)?.winner == .managed)
        #expect(managedOff.lockedByManaged(path))
    }

    @Test func codeModeIsOnOnlyFromUserAndIgnoredInProjectAndLocal() throws {
        let path = ["env", "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"]
        let repo = LayersFixtures.settings(
            (.user, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"}}"#),
            (.project, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "0"}}"#)
        )
        let effective = try #require(repo.value(at: path))
        #expect(effective.value == "1")
        #expect(effective.winner == .user)
        #expect(effective.ignoredLayers == [.project])

        #expect(LayersFixtures.settings((.managed, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"}}"#)).value(at: path) == nil)
        #expect(LayersFixtures.settings((.local, #"{"env": {"CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"}}"#)).value(at: path) == nil)
    }

    @Test func restrictiveManagedValueLocksOnlyWhenNothingStricterExists() {
        func locked(_ managed: String, _ key: String) -> Bool {
            LayersFixtures.settings((.managed, managed)).lockedByManaged([key])
        }

        #expect(locked(#"{"disableClaudeAiConnectors": true}"#, "disableClaudeAiConnectors"))
        #expect(!locked(#"{"disableClaudeAiConnectors": false}"#, "disableClaudeAiConnectors"))
        #expect(locked(#"{"remoteControlAtStartup": false}"#, "remoteControlAtStartup"))
        #expect(!locked(#"{"remoteControlAtStartup": true}"#, "remoteControlAtStartup"))
        #expect(locked(#"{"crossSessionInbound": "refuse"}"#, "crossSessionInbound"))
        #expect(!locked(#"{"crossSessionInbound": "hold"}"#, "crossSessionInbound"))
        #expect(locked(#"{"useAutoModeDuringPlan": false}"#, "useAutoModeDuringPlan"))
        #expect(!locked(#"{"useAutoModeDuringPlan": true}"#, "useAutoModeDuringPlan"))
        #expect(locked(#"{"maxEffortLevel": "low"}"#, "maxEffortLevel"))
        #expect(!locked(#"{"maxEffortLevel": "medium"}"#, "maxEffortLevel"))
    }

    @Test func managedLockFollowsTheMergeRules() {
        let settings = LayersFixtures.settings(
            (.managed, #"""
            {"model": "opus", "env": {"A": "1", "N": null}, "permissions": {"allow": ["Read"]},
             "fallbackModel": ["sonnet"], "availableModels": ["opus"], "deniedModels": ["haiku"],
             "modelPicker": {"options": []}, "extraKnownMarketplaces": {"team": {"source": "x"}}, "custom": 5}
            """#),
            (.user, #"{"model": "sonnet"}"#)
        )

        #expect(settings.lockedByManaged(["model"]))
        #expect(settings.lockedByManaged(["env", "A"]))
        #expect(settings.lockedByManaged(["env", "N"]))
        #expect(!settings.lockedByManaged(["env", "B"]))
        #expect(!settings.lockedByManaged(["env"]))
        #expect(!settings.lockedByManaged(["permissions", "allow"]))
        #expect(!settings.lockedByManaged(["permissions"]))
        #expect(settings.lockedByManaged(["fallbackModel"]))
        #expect(settings.lockedByManaged(["availableModels"]))
        #expect(settings.lockedByManaged(["deniedModels"]))
        #expect(settings.lockedByManaged(["modelPicker", "replaceBuiltInOptions"]))
        #expect(settings.lockedByManaged(["extraKnownMarketplaces", "team", "autoUpdate"]))
        #expect(!settings.lockedByManaged(["extraKnownMarketplaces", "other"]))
        #expect(settings.lockedByManaged(["custom", "nested"]))
        #expect(!settings.lockedByManaged(["outputStyle"]))
        #expect(!settings.lockedByManaged([]))
    }

    @Test func noManagedLayerLocksNothing() {
        let invalid = EffectiveSettings(layers: [
            LayersFixtures.layer(.managed, "[]"),
            LayersFixtures.layer(.user, #"{"model": "opus"}"#),
        ])
        #expect(!invalid.lockedByManaged(["model"]))
        #expect(!LayersFixtures.settings((.user, #"{"model": "opus"}"#)).lockedByManaged(["model"]))
    }

    @Test func lockedTweakUsesItsLocation() {
        let tweak = LayersFixtures.tweak("CLAUDE_CODE_X", .env(name: "CLAUDE_CODE_X"), .flag)
        let settings = LayersFixtures.settings((.managed, #"{"env": {"CLAUDE_CODE_X": "1"}}"#))
        #expect(settings.lockedByManaged(tweak))
    }
}
