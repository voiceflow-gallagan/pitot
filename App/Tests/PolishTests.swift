import AppKit
import Foundation
import PitotCore
import Testing

@testable import Pitot

@MainActor
struct CommandTests {
    private func commands(_ model: SettingsModel, editing: Bool = false, sheet: Bool = false) -> CommandAvailability {
        CommandAvailability.make(model: model, isEditingText: editing, hasSheet: sheet)
    }

    @Test func applyAndDiscardNeedPendingChangesInTheSection() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        var available = commands(model)
        #expect(!available.apply && !available.discard && !available.undo)
        #expect(available.undoTitle == "Undo Last Change")
        #expect(available.runSetupQuestions && available.chooseProject && available.goToSection && available.find)

        model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        available = commands(model)
        #expect(available.apply && available.discard)

        model.select(.keybindings)
        available = commands(model)
        #expect(!available.apply && !available.discard && !available.chooseProject)
        model.keybindings.request(.add(context: "Chat", key: "ctrl+j", action: "chat:clearScreen"))
        #expect(commands(model).apply && commands(model).discard)
        model.discardInSection()
        #expect(!model.keybindings.hasPending)
        #expect(model.hasPending)

        model.select(.unverified)
        available = commands(model)
        #expect(available.apply && available.chooseProject)

        model.select(.category("Interface"))
        await model.applyInSection()
        available = commands(model)
        #expect(!available.apply && !available.discard && available.undo)
    }

    @Test func writingDisablesWhatWouldWrite() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        model.isWriting = true
        let available = commands(model)
        #expect(!available.apply && !available.discard && !available.chooseProject && !available.runSetupQuestions)
        #expect(available.goToSection && available.find)
    }

    @Test func undoActsOnTextWhileATextFieldHasFocus() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        let editing = commands(model, editing: true)
        #expect(editing.undoTitle == "Undo")
        #expect(editing.undo && editing.redo && editing.undoActsOnText)
        #expect(!editing.apply && !editing.discard)

        let notEditing = commands(model)
        #expect(!notEditing.redo && !notEditing.undoActsOnText)
    }

    @Test func anOpenSheetDisablesTheWindowCommands() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        await model.applyInSection()
        model.requestChange(nil, for: try fixture.tweak("tui"))
        #expect(commands(model).apply && commands(model).undo)
        #expect(commands(model, sheet: true) == CommandAvailability())
        #expect(commands(model, editing: true, sheet: true).undo)
    }

    @Test func setupQuestionsWaitForTheFileAndForAnOpenRun() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        #expect(model.canRunSetupQuestions)
        model.startOnboarding()
        #expect(!model.canRunSetupQuestions)
        model.finishOnboarding()
        #expect(model.canRunSetupQuestions)
    }

    @Test func goToShortcutsFollowTheSidebarOrder() async throws {
        let fixture = try await ModelFixture.make()
        let shortcuts = fixture.model.goToShortcuts
        #expect(shortcuts.map(\.item) == fixture.model.sidebarItems)
        #expect(shortcuts.map(\.key) == ["1", "2", "3", "4", "5", "6", "7"])
    }

    @Test func helpMenuOpensTheProjectPages() {
        #expect(ProjectLinks.helpItems.map(\.title) == ["Pitot on GitHub", "Report a Security Issue", "Release Notes"])
        #expect(
            ProjectLinks.helpItems.map { $0.url?.absoluteString } == [
                "https://github.com/voiceflow-gallagan/pitot",
                "https://github.com/voiceflow-gallagan/pitot/security/advisories/new",
                "https://github.com/voiceflow-gallagan/pitot/releases",
            ])
        #expect(AboutInfo.projectPage == ProjectLinks.repository)
    }
}

@MainActor
struct SessionTests {
    @Test func sectionScopeAndProjectComeBackAtTheNextLaunch() async throws {
        let session = MemorySession()
        let fixture = try await ModelFixture.make(session: session)
        let project = try fixture.makeProject(shared: "{}\n")
        fixture.model.select(.keybindings)
        await fixture.model.selectProject(project)
        fixture.model.selectScope(.project)
        #expect(session.section == "keybindings")
        #expect(session.scope == "project")
        #expect(session.projectPath == project.standardizedFileURL.path)

        let next = try await ModelFixture.make(session: session)
        await next.model.restoreSession()
        #expect(next.model.section == .keybindings)
        #expect(next.model.projectFolder == project.standardizedFileURL)
        #expect(next.model.scope == .project)

        next.model.closeProject()
        #expect(session.projectPath == nil)
        #expect(session.scope == "user")
    }

    @Test func whatNoLongerExistsIsSkipped() async throws {
        let session = MemorySession()
        session.section = "category:Gone"
        session.scope = "local"
        session.projectPath = "/nonexistent/\(UUID().uuidString)"
        let fixture = try await ModelFixture.make(session: session)
        await fixture.model.restoreSession()
        #expect(fixture.model.section == .category("Interface"))
        #expect(fixture.model.projectFolder == nil)
        #expect(fixture.model.scope == .user)
        #expect(session.projectPath == nil)
    }

    @Test func sectionIdsRoundTrip() {
        for item in [SidebarItem.category("Model and cost"), .keybindings, .unverified] {
            #expect(SidebarItem(id: item.id) == item)
        }
        #expect(SidebarItem(id: "nonsense") == nil)
    }

    @Test func userDefaultsKeepOnlyNamesAndAPath() throws {
        let suite = "PitotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSession(defaults: defaults)
        store.section = "keybindings"
        store.scope = "local"
        store.projectPath = "/work/app"
        let saved = try #require(defaults.persistentDomain(forName: suite))
        #expect(saved.count == 3)
        #expect(saved.values.allSatisfy { $0 is String })
        store.projectPath = nil
        #expect(defaults.string(forKey: UserDefaultsSession.projectKey) == nil)
    }

    @Test func sessionIsOffForCustomPathAndTestRuns() {
        #expect(SessionStores.store(mode: .custom, environment: [:]) == nil)
        #expect(SessionStores.store(mode: .copy, environment: ["XCTestConfigurationFilePath": "/x"]) == nil)
        #expect(SessionStores.store(mode: .real, environment: [:]) != nil)
    }
}

struct AccessibilityTextTests {
    @Test func badgeTextReadsOnEveryTintInEveryAppearance() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for style in Array(SidebarStyles.table.values) + [SidebarStyles.fallback] {
            for name in appearances {
                let appearance = try #require(NSAppearance(named: name))
                let ink = BadgeInk.color(on: style.nsTint, in: appearance)
                #expect(BadgeInk.contrast(ink, style.nsTint, in: appearance) >= 4.5, "\(style.tintName) in \(name.rawValue)")
            }
        }
    }

    @Test func reviewLinesSayWhatKindTheyAre() {
        #expect(ReviewLineKind.change.spokenText("Renderer: Default to Fullscreen") == "Change: Renderer: Default to Fullscreen")
        #expect(ReviewLineKind.warning.spokenText("Effort is capped.") == "Warning: Effort is capped.")
        #expect(ReviewLineKind.problem.spokenText("Needs a newer Claude Code.") == "Problem: Needs a newer Claude Code.")
        #expect(ReviewLineKind.autoSet.spokenText("Also turning on Renderer") == "Also turning on Renderer")
    }
}
