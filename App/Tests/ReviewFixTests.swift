import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct ReviewFixTests {
    private func link(_ link: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    // MARK: Confinement

    @Test func projectFileLinkedOutsideTheProjectIsNeverReadOrWritten() async throws {
        let fixture = try await ModelFixture.make()
        let outside = fixture.folder.appendingPathComponent("outside.json")
        let outsideText = "{\n  \"model\": \"haiku\"\n}\n"
        try outsideText.write(to: outside, atomically: true, encoding: .utf8)
        let project = try fixture.makeProject()
        try link(project.appendingPathComponent(".claude/settings.local.json"), to: outside)

        await fixture.model.selectProject(project)
        let local = try #require(fixture.model.projectStores?.local)
        #expect(local.layer.state == .unreadable(ErrorText.outsideProject))
        #expect(local.problem?.contains(ErrorText.outsideProject) == true)
        #expect(!fixture.model.canEditScope)
        #expect(fixture.model.effective.value(at: ["model"])?.winner == .user)

        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        #expect(!fixture.model.hasPending)
        let operations: [JSONEdit.Operation] = [.set(path: ["model"], value: .json("sonnet"))]
        #expect(await fixture.model.write(operations, to: local, expectedHash: SettingsFile.missingFileHash) == false)
        #expect(try String(contentsOf: outside, encoding: .utf8) == outsideText)
        #expect(try fixture.backupCount() == 0)
    }

    @Test func linkInsideTheProjectIsFollowed() async throws {
        let fixture = try await ModelFixture.make()
        let project = try fixture.makeProject()
        let real = project.appendingPathComponent("real-local.json")
        try "{\n  \"model\": \"sonnet\"\n}\n".write(to: real, atomically: true, encoding: .utf8)
        try link(project.appendingPathComponent(".claude/settings.local.json"), to: real)

        await fixture.model.selectProject(project)
        #expect(fixture.model.canEditScope)
        #expect(fixture.model.effective.value(at: ["model"])?.winner == .local)
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        await fixture.model.applyPending()
        #expect(try String(contentsOf: real, encoding: .utf8).contains("\"showThinkingSummaries\": true"))
    }

    @Test func userFileLinkIsStillFollowed() async throws {
        let fixture = try await ModelFixture.make()
        let elsewhere = fixture.folder.appendingPathComponent("Elsewhere/real-settings.json")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ModelFixture.initial.write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.url)
        try link(fixture.url, to: elsewhere)

        await fixture.model.reload()
        #expect(fixture.model.user.problem == nil)
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        #expect(try String(contentsOf: elsewhere, encoding: .utf8).contains("\"tui\": \"fullscreen\""))
    }

    // MARK: Size limit

    @Test func fileOverEightMegabytesIsUnreadable() async throws {
        let fixture = try await ModelFixture.make()
        let padding = String(repeating: " ", count: 9 * 1024 * 1024)
        try "{\"model\": \"opus\"}\(padding)".write(to: fixture.url, atomically: true, encoding: .utf8)
        await fixture.model.reload()
        #expect(fixture.model.user.layer.state == .unreadable(ErrorText.tooLarge))
        #expect(fixture.model.user.problem?.contains("larger than 8 MB") == true)
        #expect(!fixture.model.canEditScope)
        #expect(ErrorText.describe(.io(operation: .read, path: "/x", errno: EFBIG)) == ErrorText.tooLarge)
    }

    // MARK: Undo that cannot be forced

    @Test func arrayChangeCannotBeForced() async throws {
        let file = """
            {
              "bindings": [
                {"context": "Chat", "bindings": {"ctrl+k": "chat:clearInput"}}
              ]
            }

            """
        let fixture = try await ModelFixture.make(keybindings: file)
        let keybindings = fixture.model.keybindings
        keybindings.request(.add(context: "Global", key: "ctrl+t", action: "app:toggleTodos"))
        await keybindings.apply()
        let written = try String(contentsOf: keybindings.url, encoding: .utf8)
        try written.replacingOccurrences(of: "\"ctrl+k\": \"chat:clearInput\"", with: "\"ctrl+j\": \"chat:clearInput\"")
            .write(to: keybindings.url, atomically: true, encoding: .utf8)
        try written.replacingOccurrences(of: "{\"context\": \"Chat\", \"bindings\": {\"ctrl+k\": \"chat:clearInput\"}},", with: "")
            .write(to: keybindings.url, atomically: true, encoding: .utf8)

        await keybindings.undo()
        #expect(keybindings.blockedUndo != nil)
        await keybindings.undo(force: true)
        #expect(keybindings.blockedUndo == nil)
        #expect(keybindings.errorMessage?.hasPrefix("This change cannot be forced because the list changed. Undo it by hand") == true)
        #expect(keybindings.canUndo)
    }

    // MARK: Keybindings header

    @Test func headerErrorsAreReadable() async throws {
        let fixture = try await ModelFixture.make()
        #expect(fixture.model.keybindings.headerProblem == nil)
        let text = ErrorText.describe(KeybindingsFileError.initialContentInvalid(.unexpectedEnd))
        #expect(text.contains("header for a new keybindings file is not valid JSON"))
    }

    // MARK: Project cache

    @Test func projectCacheKeepsTheFiftyNewest() async throws {
        let fixture = try await ModelFixture.make()
        var projects: [URL] = []
        for _ in 0...SettingsModel.projectCacheLimit {
            let project = try fixture.makeProject()
            projects.append(project)
            await fixture.model.selectProject(project)
        }
        #expect(fixture.model.projectCache.count == SettingsModel.projectCacheLimit)
        #expect(fixture.model.projectCache[projects[0].standardizedFileURL.path] == nil)
        #expect(fixture.model.projectCache[projects[SettingsModel.projectCacheLimit].standardizedFileURL.path] != nil)

        await fixture.model.selectProject(projects[1])
        let next = try fixture.makeProject()
        await fixture.model.selectProject(next)
        #expect(fixture.model.projectCache[projects[1].standardizedFileURL.path] != nil)
        #expect(fixture.model.projectCache[projects[2].standardizedFileURL.path] == nil)
    }
}
