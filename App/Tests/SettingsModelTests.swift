import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct SettingsModelTests {
    @Test func bundledCatalogLoadsInCatalogOrder() async throws {
        let fixture = try await ModelFixture.make()
        #expect(fixture.model.catalog.tweaks.count >= 30)
        #expect(fixture.model.categories == ["Interface", "Notifications", "Model and cost", "Privacy", "Safety"])
        #expect(fixture.model.selectedCategory == "Interface")
    }

    @Test func pendingChangeIsNotWrittenAndTogglingBackClearsIt() async throws {
        let fixture = try await ModelFixture.make()
        let summaries = try fixture.tweak("showThinkingSummaries")
        fixture.model.requestChange(true, for: summaries)
        #expect(fixture.model.row(summaries).isPending)
        #expect(fixture.model.review.diff.contains { $0.kind == .added && $0.text.contains("true") })
        #expect(try fixture.text() == ModelFixture.initial)

        fixture.model.requestChange(false, for: summaries)
        #expect(!fixture.model.hasPending)
    }

    @Test func groupedApplyWritesOnceWithOneBackup() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        fixture.model.requestChange(true, for: try fixture.tweak("DISABLE_ERROR_REPORTING"))
        #expect(fixture.model.review.operations.count == 3)

        await fixture.model.applyPending()
        let written = try fixture.text()
        #expect(written.contains("\"showThinkingSummaries\": true"))
        #expect(written.contains("\"tui\": \"fullscreen\""))
        #expect(written.contains("\"DISABLE_ERROR_REPORTING\": \"1\""))
        #expect(try fixture.backupCount() == 1)
        #expect(fixture.model.user.undoLog.entries.count == 1)
        // Operations follow catalog order; `env` did not exist, so the new object is the changed key.
        #expect(fixture.model.user.undoLog.entries.first?.keys == [["tui"], ["showThinkingSummaries"], ["env"]])
        #expect(!fixture.model.hasPending)
    }

    @Test func envFlagWritesOneAndOffRemovesKey() async throws {
        let fixture = try await ModelFixture.make()
        let reporting = try fixture.tweak("DISABLE_ERROR_REPORTING")
        fixture.model.requestChange(true, for: reporting)
        await fixture.model.applyPending()
        let on = try fixture.text()
        #expect(on.contains("\"DISABLE_ERROR_REPORTING\": \"1\""))

        fixture.model.requestChange(false, for: reporting)
        await fixture.model.applyPending()
        let off = try fixture.text()
        #expect(!off.contains("DISABLE_ERROR_REPORTING"))
        #expect(!on.contains("\"0\"") && !off.contains("\"0\""))
    }

    @Test func groupUndoKeepsOutsideEdit() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        try fixture.write(try fixture.text().replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))

        await fixture.model.undo()
        #expect(try fixture.text() == ModelFixture.initial.replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))
        #expect(!fixture.model.canUndo)
        #expect(fixture.model.blockedUndo == nil)
    }

    @Test func undoReportsKeysChangedSinceAndForceUndoes() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        try fixture.write(try fixture.text().replacingOccurrences(of: "\"showThinkingSummaries\": true", with: "\"showThinkingSummaries\": 7"))

        await fixture.model.undo()
        #expect(fixture.model.blockedUndo == [["showThinkingSummaries"]])
        #expect(fixture.model.canUndo)
        #expect(try fixture.text().contains("\"tui\": \"fullscreen\""))

        await fixture.model.undo(force: true)
        #expect(fixture.model.blockedUndo == nil)
        #expect(!fixture.model.canUndo)
        #expect(try fixture.text() == ModelFixture.initial)
    }

    @Test func historyLabelsEnvKeysByName() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange(true, for: try fixture.tweak("DISABLE_ERROR_REPORTING"))
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        let group = try #require(fixture.model.user.undoLog.entries.first)
        #expect(group.keys.contains(["env"]))
        #expect(fixture.model.history.first?.keys == ["tui", "env.DISABLE_ERROR_REPORTING"])
        #expect(fixture.model.history.first?.layer == "User")

        await fixture.model.undo()
        #expect(fixture.model.user.historyKeys.isEmpty)
        #expect(fixture.model.history.isEmpty)
    }

    @Test func historyListsGroupsNewestFirst() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        await fixture.model.applyPending()
        #expect(fixture.model.history.map(\.keys) == [["showThinkingSummaries"], ["tui"]])
        #expect(fixture.model.history.map(\.isNewestInLayer) == [true, false])
    }

    @Test func externalEditShowsBannerButOwnWriteDoesNot() async throws {
        let fixture = try await ModelFixture.make()
        await fixture.model.start()
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        await fixture.model.applyPending()
        try await Task.sleep(for: .seconds(1))
        #expect(!fixture.model.externalChangeBanner)

        try fixture.write("{\n  \"model\": \"sonnet\"\n}\n")
        for _ in 0..<40 where !fixture.model.externalChangeBanner {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(fixture.model.externalChangeBanner)
        fixture.model.stop()
    }

    @Test func searchFiltersByTitleKeyAndDescription() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        func ids() -> [String] { model.visibleSections.flatMap(\.tweaks).map(\.id) }

        model.searchText = "telemetry"
        #expect(ids().contains("DISABLE_TELEMETRY"))
        #expect(!ids().contains("tui"))

        model.searchText = "env.CLAUDE_CODE_SUBAGENT"
        #expect(ids() == ["CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"])

        model.searchText = "shimmer"
        #expect(ids() == ["prefersReducedMotion"])

        model.searchText = "no such setting"
        #expect(model.visibleSections.isEmpty)

        model.searchText = ""
        model.selectedCategory = "Safety"
        #expect(model.visibleSections.map(\.category) == ["Safety"])
    }
}
