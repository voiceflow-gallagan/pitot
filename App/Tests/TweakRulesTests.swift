import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct TweakRulesTests {
    @Test func focusViewAutoSetsFullscreenAndSaysWhy() async throws {
        let fixture = try await ModelFixture.make()
        let tui = try fixture.tweak("tui")
        fixture.model.requestChange("focus", for: try fixture.tweak("viewMode"))
        #expect(Array(fixture.model.pending.keys) == ["viewMode"])
        #expect(fixture.model.review.autoSets.map(\.id) == ["tui"])
        #expect(fixture.model.review.autoSets.first?.text == "Also turning on Renderer (Fullscreen) because focus view needs the fullscreen renderer.")
        #expect(fixture.model.row(tui).autoSet?.value == "fullscreen")
        #expect(fixture.model.row(tui).displayed == "fullscreen")
        #expect(fixture.model.review.diff.contains { $0.kind == .added && $0.text.contains("\"tui\": \"fullscreen\"") })
        #expect(fixture.model.pendingCount(in: "Interface") == 2)

        await fixture.model.applyPending()
        let written = try fixture.text()
        #expect(written.contains("\"viewMode\": \"focus\""))
        #expect(written.contains("\"tui\": \"fullscreen\""))
        #expect(fixture.model.user.undoLog.entries.count == 1)
        #expect(try fixture.backupCount() == 1)
    }

    @Test func leavingFullscreenUnderFocusOffersToClearFocus() async throws {
        let fixture = try await ModelFixture.make("{\n  \"tui\": \"fullscreen\",\n  \"viewMode\": \"focus\"\n}\n")
        fixture.model.requestChange("default", for: try fixture.tweak("tui"))
        #expect(fixture.model.review.suggestions.map(\.tweakId) == ["viewMode"])
        #expect(!fixture.model.review.warnings.isEmpty)

        fixture.model.requestChange(nil, for: try fixture.tweak("viewMode"))
        #expect(Set(fixture.model.pending.keys) == ["tui", "viewMode"])
        #expect(fixture.model.review.suggestions.isEmpty)
    }

    @Test func disabledRowCannotTakePendingValue() async throws {
        #expect(CatalogLinter.lint(sandboxCatalog).isEmpty)
        let fixture = try await ModelFixture.make(catalog: sandboxCatalog)
        let sandbox = try fixture.tweak("sandbox.enabled")
        let dependent = try fixture.tweak("sandbox.failIfUnavailable")
        #expect(fixture.model.row(dependent).disabledReason == "Needs the sandbox on.")

        fixture.model.requestChange(true, for: dependent)
        #expect(!fixture.model.hasPending)

        fixture.model.requestChange(true, for: sandbox)
        #expect(fixture.model.row(dependent).disabledReason == nil)
        fixture.model.requestChange(true, for: dependent)
        #expect(fixture.model.pending["sandbox.failIfUnavailable"]?.value == true)

        fixture.model.requestChange(nil, for: sandbox)
        #expect(!fixture.model.review.canApply)
        #expect(fixture.model.review.problems == ["Fail without sandbox: Needs the sandbox on."])
    }

    @Test func versionGatedRowIsDisabled() async throws {
        let fixture = try await ModelFixture.make(claudeVersion: "2.1.200")
        await fixture.model.probeClaude()
        #expect(fixture.model.claude.version?.description == "2.1.200")
        let effort = try fixture.tweak("maxEffortLevel")
        let state = fixture.model.row(effort)
        #expect(state.versionStatus == .needs("2.1.267"))
        #expect(state.disabledReason?.contains("Needs Claude Code 2.1.267") == true)

        fixture.model.requestChange("high", for: effort)
        #expect(!fixture.model.hasPending)
    }

    @Test func unknownVersionWarnsButStaysEnabled() async throws {
        let fixture = try await ModelFixture.make()
        await fixture.model.probeClaude()
        #expect(fixture.model.claude == .notFound)
        let effort = try fixture.tweak("maxEffortLevel")
        let state = fixture.model.row(effort)
        #expect(state.disabledReason == nil)
        #expect(state.notes.contains { $0.kind == .warning && $0.text.contains("could not check") })

        fixture.model.requestChange("high", for: effort)
        #expect(fixture.model.pending["maxEffortLevel"]?.value == "high")
    }

    @Test func confirmRequiredChangeWaitsForConfirmation() async throws {
        let fixture = try await ModelFixture.make()
        let telemetry = try fixture.tweak("DISABLE_TELEMETRY")
        #expect(fixture.model.needsConfirm(telemetry, to: true))

        fixture.model.requestChange(true, for: telemetry)
        #expect(!fixture.model.hasPending)
        #expect(fixture.model.confirmRequest?.tweakId == "DISABLE_TELEMETRY")
        #expect(fixture.model.confirmRequest?.message == telemetry.confirm?.message)

        fixture.model.cancelConfirm()
        #expect(!fixture.model.hasPending)
        #expect(fixture.model.confirmRequest == nil)

        fixture.model.requestChange(true, for: telemetry)
        await fixture.model.confirmChange()
        #expect(fixture.model.pending["DISABLE_TELEMETRY"]?.value == true)
        #expect(fixture.model.confirmRequest == nil)

        fixture.model.requestChange(false, for: telemetry)
        #expect(!fixture.model.hasPending)
        #expect(fixture.model.confirmRequest == nil)
    }

    @Test func turningSandboxOffNeedsConfirmation() async throws {
        let fixture = try await ModelFixture.make("{\n  \"sandbox\": {\n    \"enabled\": true\n  }\n}\n")
        fixture.model.requestChange(false, for: try fixture.tweak("sandbox.enabled"))
        #expect(!fixture.model.hasPending)
        #expect(fixture.model.confirmRequest?.tweakId == "sandbox.enabled")
    }

    @Test func sandboxResetToDefaultNeedsConfirmButTurningOnDoesNot() async throws {
        let on = try await ModelFixture.make("{\n  \"sandbox\": {\n    \"enabled\": true\n  }\n}\n")
        let sandbox = try on.tweak("sandbox.enabled")
        #expect(on.model.needsConfirm(sandbox, to: nil))
        on.model.requestChange(nil, for: sandbox)
        #expect(on.model.confirmRequest?.tweakId == "sandbox.enabled")
        #expect(!on.model.hasPending)

        let off = try await ModelFixture.make("{\n  \"sandbox\": {\n    \"enabled\": false\n  }\n}\n")
        off.model.requestChange(true, for: try off.tweak("sandbox.enabled"))
        #expect(off.model.confirmRequest == nil)
        #expect(off.model.pending["sandbox.enabled"]?.value == true)
    }

    @Test func envRowsCarryTheEnvBlockNote() async throws {
        let fixture = try await ModelFixture.make()
        let envNote = RowNote(kind: .quiet, text: RowState.envNote)
        #expect(fixture.model.row(try fixture.tweak("DISABLE_TELEMETRY")).notes.contains(envNote))
        #expect(!fixture.model.row(try fixture.tweak("showThinkingSummaries")).notes.contains(envNote))
    }

    @Test func unrecognizedValueShowsAndCanBeReset() async throws {
        let fixture = try await ModelFixture.make("{\n  \"tui\": 42,\n  \"theme\": \"neon\"\n}\n")
        let tui = try fixture.tweak("tui")
        #expect(fixture.model.row(tui).reading == .unrecognized(42))
        #expect(fixture.model.row(tui).unrecognizedText == "42")
        #expect(fixture.model.row(tui).showsUnrecognized)
        #expect(fixture.model.row(try fixture.tweak("theme")).unrecognizedText == "\"neon\"")

        fixture.model.requestChange(nil, for: tui)
        #expect(!fixture.model.row(tui).showsUnrecognized)
        #expect(fixture.model.review.changes.map(\.text) == ["Renderer: 42 → not set"])

        await fixture.model.applyPending()
        let written = try fixture.text()
        #expect(!written.contains("tui"))
        #expect(written.contains("\"theme\": \"neon\""))
    }

    @Test func invalidPendingValueBlocksApply() async throws {
        let fixture = try await ModelFixture.make()
        let plans = try fixture.tweak("plansDirectory")
        #expect(fixture.model.validationMessage(for: plans, text: "   ") == "The value must not be empty.")
        fixture.model.commitText("   ", for: plans)
        #expect(fixture.model.pending["plansDirectory"] != nil)
        #expect(fixture.model.review.problems == ["Plans folder: The value must not be empty."])
        #expect(!fixture.model.review.canApply)

        fixture.model.commitText("", for: plans)
        #expect(!fixture.model.hasPending)
    }

    @Test func envOverrideInFileShowsOnRow() async throws {
        let fixture = try await ModelFixture.make("{\n  \"tui\": \"fullscreen\",\n  \"env\": {\n    \"CLAUDE_CODE_NO_FLICKER\": \"false\"\n  }\n}\n")
        let notes = fixture.model.row(try fixture.tweak("tui")).notes
        #expect(notes.contains { $0.kind == .warning && $0.text.contains("CLAUDE_CODE_NO_FLICKER=false") })

        let quiet = try await ModelFixture.make("{\n  \"env\": {\n    \"CLAUDE_CODE_NO_FLICKER\": \"1\"\n  }\n}\n")
        #expect(quiet.model.row(try quiet.tweak("tui")).notes.isEmpty)
    }

    @Test func previewErrorBlocksApplyWhenEnvIsNotAnObject() async throws {
        let fixture = try await ModelFixture.make("{\n  \"env\": 5\n}\n")
        fixture.model.requestChange(true, for: try fixture.tweak("DISABLE_ERROR_REPORTING"))
        #expect(fixture.model.review.previewError?.contains("env is not an object") == true)
        #expect(!fixture.model.review.canApply)
    }
}
