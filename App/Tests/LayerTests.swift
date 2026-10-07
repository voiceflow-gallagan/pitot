import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct LayerTests {
    private func localURL(_ project: URL) -> URL {
        project.appendingPathComponent(".claude/settings.local.json")
    }

    private func sharedURL(_ project: URL) -> URL {
        project.appendingPathComponent(".claude/settings.json")
    }

    private func decoded(_ url: URL) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    @Test func scopeNeedsAProjectAndProjectSelectsLocal() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        #expect(model.scope == .user)
        #expect(!model.selectScope(.local))
        #expect(model.scope == .user)

        let project = try fixture.makeProject()
        await model.selectProject(project)
        #expect(model.scope == .local)
        #expect(model.selectedStore?.url == localURL(project))
        #expect(fixture.recent.paths == [project.path])
        #expect(model.selectScope(.project))
        #expect(model.selectedStore?.url == sharedURL(project))

        model.closeProject()
        #expect(model.scope == .user)
        #expect(model.projectFolder == nil)
    }

    @Test func rowShowsEffectiveValueAndItsSource() async throws {
        let fixture = try await ModelFixture.make()
        let project = try fixture.makeProject(local: "{\n  \"model\": \"sonnet\"\n}\n")
        await fixture.model.selectProject(project)
        fixture.model.selectScope(.user)
        let state = fixture.model.row(try fixture.tweak("model"))
        #expect(state.reading == .value("opus"))
        #expect(state.effective.winner == .local)
        #expect(state.effective.reading == .value("sonnet"))
        #expect(state.notes.contains { $0.text == "In effect: sonnet, set in Project-local" })
        #expect(state.overriddenBy == .local)

        fixture.model.switchScope(to: .local)
        #expect(fixture.model.scope == .local)
        #expect(fixture.model.row(try fixture.tweak("model")).overriddenBy == nil)
    }

    @Test func userWriteShadowedByLocalIsWarned() async throws {
        let fixture = try await ModelFixture.make()
        await fixture.model.selectProject(try fixture.makeProject(local: "{\n  \"model\": \"sonnet\"\n}\n"))
        fixture.model.selectScope(.user)
        fixture.model.commitText("haiku", for: try fixture.tweak("model"))
        #expect(fixture.model.review.shadowed.map(\.text) == ["Default model: this change will not take effect. Project-local sets it to sonnet."])
        #expect(fixture.model.review.canApply)
    }

    @Test func managedKeyLocksTheRowAndIsNeverWritten() async throws {
        let managedText = "{\n  \"model\": \"opus\"\n}\n"
        let fixture = try await ModelFixture.make(managed: managedText)
        let model = try fixture.tweak("model")
        let state = fixture.model.row(model)
        #expect(state.isLocked)
        #expect(state.disabledReason == RowState.lockedText)
        #expect(state.notes.contains { $0.kind == .locked })

        fixture.model.commitText("haiku", for: model)
        #expect(!fixture.model.hasPending)
        #expect(LayerID.managed.writableKind == nil)
        fixture.model.switchScope(to: .managed)
        #expect(fixture.model.scope == .user)

        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        let managedFile = fixture.folder.appendingPathComponent("Managed/managed-settings.json")
        #expect(try String(contentsOf: managedFile, encoding: .utf8) == managedText)
        #expect(fixture.model.stores.allSatisfy { $0.url != managedFile })
    }

    @Test func userOnlyRowsAndValuesAreRefusedInProjectLayers() async throws {
        let fixture = try await ModelFixture.make()
        await fixture.model.selectProject(try fixture.makeProject())
        let timeout = try fixture.tweak("askUserQuestionTimeout")
        let state = fixture.model.row(timeout)
        #expect(state.rowRefusal != nil)
        #expect(state.disabledReason == state.rowRefusal)
        fixture.model.requestChange("5m", for: timeout)
        #expect(!fixture.model.hasPending)

        let mode = try fixture.tweak("permissions.defaultMode")
        fixture.model.requestChange("bypassPermissions", for: mode)
        #expect(!fixture.model.hasPending)
        #expect(fixture.model.refusals["permissions.defaultMode"]?.contains("user settings") == true)
        #expect(fixture.model.row(mode).notes.contains { $0.kind == .disabled })

        fixture.model.requestChange("acceptEdits", for: mode)
        #expect(fixture.model.pending["permissions.defaultMode"]?.value == "acceptEdits")
        #expect(fixture.model.refusals.isEmpty)
    }

    @Test func missingLocalFileIsCreatedAndUndoRemovesIt() async throws {
        let fixture = try await ModelFixture.make()
        let project = try fixture.makeProject()
        await fixture.model.selectProject(project)
        #expect(fixture.model.selectedStore?.isMissing == true)
        #expect(fixture.model.canEditScope)

        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        #expect(fixture.model.review.createsFile == localURL(project))
        #expect(fixture.model.review.diff.allSatisfy { $0.kind == .added })
        await fixture.model.applyPending()
        #expect(try decoded(localURL(project)) == ["showThinkingSummaries": true])
        #expect(fixture.model.history.first?.layer == "Project-local · \(project.lastPathComponent)")

        await fixture.model.undo()
        #expect(!FileManager.default.fileExists(atPath: localURL(project).path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
        #expect(fixture.model.selectedStore?.isMissing == true)
        #expect(!fixture.model.canUndo)
    }

    @Test func sharedProjectFileAsksBeforeWriting() async throws {
        let fixture = try await ModelFixture.make()
        let project = try fixture.makeProject()
        await fixture.model.selectProject(project)
        fixture.model.selectScope(.project)
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))

        await fixture.model.applyPending()
        #expect(fixture.model.confirmRequest?.action == .writeSharedProject)
        #expect(fixture.model.confirmRequest?.message == "This file is usually committed to git and shared with your team.")
        #expect(!FileManager.default.fileExists(atPath: sharedURL(project).path))

        fixture.model.cancelConfirm()
        #expect(fixture.model.hasPending)
        #expect(!FileManager.default.fileExists(atPath: sharedURL(project).path))

        await fixture.model.applyPending()
        await fixture.model.confirmChange()
        #expect(try decoded(sharedURL(project)) == ["showThinkingSummaries": true])
        #expect(!fixture.model.hasPending)
    }

    @Test func projectsReaderKeepsOnlyPathsAndNoSecrets() async throws {
        let fixture = try await ModelFixture.make()
        let first = try fixture.makeProject()
        let second = try fixture.makeProject()
        let claudeJSON = fixture.folder.appendingPathComponent("claude.json")
        let content = """
            {
              "oauthAccount": {"accessToken": "SECRET-OAUTH-TOKEN", "emailAddress": "secret@example.com"},
              "primaryApiKey": "SECRET-API-KEY",
              "projects": {
                "\(first.path)": {"lastSessionId": "SECRET-SESSION", "env": {"API_KEY": "SECRET-PROJECT-KEY"}},
                "/no/such/folder/SECRET-PATH-GONE": {"allowedTools": []},
                "\(second.path)": {"history": [{"display": "SECRET-PROMPT"}]}
              },
              "userID": "SECRET-USER-ID"
            }
            """
        try content.write(to: claudeJSON, atomically: true, encoding: .utf8)
        let reader = ClaudeJSONProjects(url: claudeJSON)
        #expect(reader.projectPaths() == [first.path, "/no/such/folder/SECRET-PATH-GONE", second.path])

        let withReader = try await ModelFixture.make(suggestions: reader)
        await withReader.model.loadProjectSuggestions()
        #expect(withReader.model.projectChoices.map(\.url.path) == [second.path, first.path])
        var state = ""
        dump(withReader.model.projectChoices, to: &state)
        dump(withReader.model.projectSuggestionPaths, to: &state)
        dump(withReader.model, to: &state)
        #expect(!state.contains("SECRET-OAUTH-TOKEN") && !state.contains("SECRET-API-KEY"))
        #expect(!state.contains("SECRET-TOKEN") && !state.contains("SECRET-KEY") && !state.contains("SECRET-SESSION"))
        #expect(!state.contains("SECRET-PROJECT-KEY") && !state.contains("SECRET-PROMPT") && !state.contains("SECRET-USER-ID"))
        #expect(!state.contains("secret@example.com"))
    }

    @Test(.enabled(if: GitIgnoreCheck.system.git != nil, "git is not installed"))
    func localFileNotIgnoredByGitIsWarned() async throws {
        let git = try #require(GitIgnoreCheck.system.git)
        // The user's global ignore file may already ignore settings.local.json, so git gets an empty HOME.
        // GIT_DIR in the parent environment must not reach git, or it would check another repository.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PitotGitHome-\(UUID().uuidString)").path
        let isolated = ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let parent = ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_DIR": "/nonexistent/.git"]
        let fixture = try await ModelFixture.make(gitCheck: GitIgnoreCheck(git: git, parentEnvironment: parent))
        let project = try fixture.makeProject()
        let process = Process()
        process.executableURL = git
        process.arguments = ["init", "-q", project.path]
        process.environment = isolated
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        await fixture.model.selectProject(project)
        await fixture.model.checkGitIgnore()
        #expect(fixture.model.localNotIgnored)

        try ".claude/settings.local.json\n".write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        await fixture.model.checkGitIgnore()
        #expect(!fixture.model.localNotIgnored)

        await fixture.model.selectProject(try fixture.makeProject())
        await fixture.model.checkGitIgnore()
        #expect(!fixture.model.localNotIgnored)
    }

    @Test func historyNamesTheLayerAndProject() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        let project = try fixture.makeProject(local: "{}\n")
        await fixture.model.selectProject(project)
        fixture.model.requestChange(true, for: try fixture.tweak("DISABLE_ERROR_REPORTING"))
        await fixture.model.applyPending()

        let history = fixture.model.history
        #expect(history.map(\.layer) == ["Project-local · \(project.lastPathComponent)", "User"])
        #expect(history.map(\.keys) == [["env.DISABLE_ERROR_REPORTING"], ["tui"]])
        #expect(history.allSatisfy { $0.isNewestInLayer })
    }

    @Test func invalidLayerDisablesEditingThere() async throws {
        let fixture = try await ModelFixture.make()
        let project = try fixture.makeProject(local: "{\n  \"outputStyle\": null\n}\n")
        await fixture.model.selectProject(project)
        let problem = try #require(fixture.model.selectedStore?.problem)
        #expect(problem.contains(localURL(project).path))
        #expect(fixture.model.layerProblems.contains(problem))
        #expect(!fixture.model.canEditScope)
        let tui = try fixture.tweak("tui")
        #expect(fixture.model.row(tui).disabledReason == problem)
        fixture.model.requestChange("fullscreen", for: tui)
        #expect(!fixture.model.hasPending)

        fixture.model.selectScope(.user)
        #expect(fixture.model.canEditScope)
        fixture.model.requestChange("fullscreen", for: tui)
        #expect(fixture.model.hasPending)
    }

    @Test func undoInOneLayerLeavesTheOthers() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await fixture.model.applyPending()
        let userAfterWrite = try fixture.text()
        let project = try fixture.makeProject(local: "{\n  \"model\": \"sonnet\"\n}\n")
        await fixture.model.selectProject(project)
        fixture.model.requestChange(true, for: try fixture.tweak("showThinkingSummaries"))
        await fixture.model.applyPending()

        await fixture.model.undo()
        #expect(try decoded(localURL(project)) == ["model": "sonnet"])
        #expect(try fixture.text() == userAfterWrite)
        #expect(!fixture.model.canUndo)
        #expect(fixture.model.user.canUndo)
    }

    @Test func turningSandboxOffLocallyConfirmsAgainstTheEffectiveValue() async throws {
        let fixture = try await ModelFixture.make("{\n  \"sandbox\": {\n    \"enabled\": true\n  }\n}\n")
        await fixture.model.selectProject(try fixture.makeProject())
        fixture.model.requestChange(false, for: try fixture.tweak("sandbox.enabled"))
        #expect(fixture.model.confirmRequest?.tweakId == "sandbox.enabled")
        #expect(!fixture.model.hasPending)
    }
}
