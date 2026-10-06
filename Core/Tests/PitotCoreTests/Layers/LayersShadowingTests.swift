import Foundation
import Testing

@testable import PitotCore

@Suite("Layers: shadowing and writes")
struct LayersShadowingTests {
    private let model = LayersFixtures.tweak("model", .setting(path: ["model"]), .string)
    private let telemetry = LayersFixtures.tweak("DISABLE_TELEMETRY", .env(name: "DISABLE_TELEMETRY"), .flag)

    @Test func higherLayersThatSetTheKeyShadowALowerOne() {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "user"}"#),
            (.project, #"{"model": "project"}"#),
            (.local, #"{"model": "local"}"#)
        )

        #expect(settings.shadowing(of: .user, at: ["model"]) == [.local, .project])
        #expect(settings.shadowing(of: .project, at: ["model"]) == [.local])
        #expect(settings.shadowing(of: .local, at: ["model"]).isEmpty)
    }

    @Test func nothingWrittenMeansNothingShadowed() {
        let settings = LayersFixtures.settings((.local, #"{"model": "local"}"#), (.user, "{}"))
        #expect(settings.shadowing(of: .user, at: ["model"]).isEmpty)
        #expect(settings.shadowing(of: .project, at: ["model"]).isEmpty)
    }

    @Test func joinedListsAndMergedObjectsAreNotShadowed() {
        let settings = LayersFixtures.settings(
            (.user, #"{"permissions": {"allow": ["a"]}, "env": {"A": "1"}}"#),
            (.local, #"{"permissions": {"allow": ["b"]}, "env": {"B": "2"}}"#)
        )
        #expect(settings.shadowing(of: .user, at: ["permissions", "allow"]).isEmpty)
        #expect(settings.shadowing(of: .user, at: ["env"]).isEmpty)
        #expect(settings.shadowing(of: .user, at: ["env", "A"]).isEmpty)
    }

    @Test func aHigherValueOfAnotherTypeShadowsTheWholePath() {
        let settings = LayersFixtures.settings(
            (.user, #"{"custom": {"a": 1}}"#),
            (.project, #"{"custom": 5}"#)
        )
        #expect(settings.shadowing(of: .user, at: ["custom", "a"]) == [.project])
    }

    @Test func restrictiveValueInALowerLayerShadowsAHigherOne() {
        let settings = LayersFixtures.settings(
            (.user, #"{"disableClaudeAiConnectors": true}"#),
            (.project, #"{"disableClaudeAiConnectors": false}"#),
            (.managed, #"{"disableClaudeAiConnectors": false}"#)
        )
        #expect(settings.shadowing(of: .project, at: ["disableClaudeAiConnectors"]) == [.managed, .user])
        #expect(settings.shadowing(of: .managed, at: ["disableClaudeAiConnectors"]) == [.user])
        #expect(settings.shadowing(of: .user, at: ["disableClaudeAiConnectors"]).isEmpty)
    }

    @Test func ignoredValueIsNotReportedAsShadowed() {
        let settings = LayersFixtures.settings(
            (.user, #"{"remoteControlAtStartup": false}"#),
            (.local, #"{"remoteControlAtStartup": true}"#)
        )
        #expect(settings.shadowing(of: .local, at: ["remoteControlAtStartup"]).isEmpty)
    }

    @Test func userWriteIsOverriddenByLocal() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "sonnet"}"#),
            (.local, #"{"model": "haiku"}"#)
        )
        let after = try #require(settings.effective(for: model, writing: .string("opus"), to: .user))

        #expect(after.value == "haiku")
        #expect(after.winner == .local)
        #expect(after.contributions.last == EffectiveValue.Contribution(layer: .user, value: "opus"))
        #expect(after.overriddenLayers == [.user])
    }

    @Test func localWriteWinsOverUserAndProject() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "sonnet"}"#),
            (.project, #"{"model": "haiku"}"#)
        )
        let after = try #require(settings.effective(for: model, writing: .string("opus"), to: .local))

        #expect(after.value == "opus")
        #expect(after.winner == .local)
        #expect(after.overriddenLayers == [.project, .user])
    }

    @Test func removingTheWinnerFallsBackToTheNextLayer() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "sonnet"}"#),
            (.local, #"{"model": "haiku"}"#)
        )

        #expect(settings.effective(for: model, writing: nil, to: .local)?.value == "sonnet")
        #expect(settings.effective(for: model, writing: nil, to: .user)?.value == "haiku")
        #expect(LayersFixtures.settings((.user, #"{"model": "sonnet"}"#)).effective(for: model, writing: nil, to: .user) == nil)
    }

    @Test func writingToAMissingLayerCreatesIt() throws {
        let settings = EffectiveSettings(layers: [
            LayersFixtures.layer(.user, #"{"model": "sonnet"}"#),
            SettingsLayer(id: .project, url: nil, state: .missing),
        ])
        let after = try #require(settings.effective(for: model, writing: .string("opus"), to: .project))

        #expect(after.winner == .project)
        #expect(after.value == "opus")
    }

    @Test func envWriteUsesTheTweakEncoding() throws {
        let settings = LayersFixtures.settings(
            (.user, #"{"env": {"OTHER": "x"}}"#),
            (.project, #"{"env": {"DISABLE_TELEMETRY": "1"}}"#)
        )

        let on = try #require(settings.effective(for: telemetry, writing: .bool(true), to: .local))
        #expect(on.value == "1")
        #expect(on.winner == .local)

        #expect(settings.effective(for: telemetry, writing: .bool(false), to: .project) == nil)
        #expect(settings.effective(for: telemetry, writing: .bool(false), to: .user)?.winner == .project)
    }

    @Test func managedValueStaysInEffectAfterAWrite() throws {
        let settings = LayersFixtures.settings((.managed, #"{"model": "opus"}"#))
        let after = try #require(settings.effective(for: model, writing: .string("haiku"), to: .local))

        #expect(after.value == "opus")
        #expect(after.winner == .managed)
        #expect(after.overriddenLayers == [.local])
    }

    @Test func restrictiveWriteBeatsManaged() throws {
        let settings = LayersFixtures.settings((.managed, #"{"disableClaudeAiConnectors": false}"#))
        let after = try #require(settings.effective(at: ["disableClaudeAiConnectors"], writing: true, to: .project))

        #expect(after.value == true)
        #expect(after.winner == .project)
    }

    @Test func writeThroughANonObjectLeavesTheSettingsAsTheyAre() {
        let settings = LayersFixtures.settings((.local, #"{"custom": 5}"#), (.user, #"{"custom": {"a": 1}}"#))
        #expect(settings.effective(at: ["custom", "a"], writing: 2, to: .local) == settings.value(at: ["custom", "a"]))
        #expect(settings.effective(at: [], writing: 2, to: .local) == settings.value(at: []))
    }

    @Test func writingNullToATypedKeyWouldDropTheFile() {
        let settings = LayersFixtures.settings(
            (.user, #"{"model": "sonnet"}"#),
            (.local, #"{"outputStyle": "x", "model": "haiku"}"#)
        )
        #expect(settings.effective(at: ["outputStyle"], writing: .null, to: .local) == nil)
        #expect(settings.effective(at: ["model"], writing: .null, to: .local)?.winner == .user)
    }

    @Test func aHypotheticalWriteChangesNothingStored() {
        let settings = LayersFixtures.settings((.user, #"{"model": "sonnet"}"#))
        _ = settings.effective(for: model, writing: .string("opus"), to: .local)

        #expect(settings.value(at: ["model"])?.value == "sonnet")
        #expect(settings.layer(.local) == nil)
    }
}
