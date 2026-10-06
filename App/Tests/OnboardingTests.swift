import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct OnboardingTests {
    static let cautious = [
        "experience": "new", "privacy": "least", "cost": "lowest", "work": "learn", "autonomy": "ask", "sessions": "one", "notifications": "off",
    ]

    /// Answers each question from `answers` and skips the rest, ending on the review step.
    private func answer(_ onboarding: OnboardingModel, _ answers: [String: String]) {
        while let question = onboarding.question {
            if let optionId = answers[question.id], let option = question.option(id: optionId) {
                onboarding.choose(option)
                onboarding.next()
            } else {
                onboarding.skip()
            }
        }
    }

    private func start(_ fixture: ModelFixture) throws -> OnboardingModel {
        fixture.model.startOnboarding()
        return try #require(fixture.model.onboarding)
    }

    @Test func questionNeedsAnAnswerOrASkip() async throws {
        let onboarding = try start(try await ModelFixture.make())
        #expect(onboarding.file.questions.count == 7)
        #expect(onboarding.question?.id == "experience")
        #expect(!onboarding.canGoNext)
        onboarding.next()
        #expect(onboarding.step == 0)

        onboarding.skip()
        #expect(onboarding.step == 1)
        onboarding.back()
        #expect(onboarding.canGoNext)
        #expect(onboarding.answers.isEmpty)
    }

    @Test func cautiousAnswersOnEmptyFileApplyAsOneGroup() async throws {
        let fixture = try await ModelFixture.make("{}\n")
        let onboarding = try start(fixture)
        answer(onboarding, Self.cautious)
        #expect(onboarding.isReviewing)
        let proposal = try #require(onboarding.proposal)
        #expect(proposal.presetLabel == .cautious)
        #expect(Set(proposal.all.map(\.tweakId)).isSuperset(of: ["sandbox.enabled", "DISABLE_TELEMETRY", "preferredNotifChannel"]))
        #expect(onboarding.lines.allSatisfy { $0.isTicked })
        #expect(onboarding.diff.contains { $0.kind == .added && $0.text.contains("\"DISABLE_TELEMETRY\": \"1\"") })

        await onboarding.apply()
        while onboarding.confirmRequest != nil {
            await onboarding.confirm()
        }
        #expect(fixture.model.onboarding == nil)
        #expect(fixture.model.user.undoLog.entries.count == 1)
        #expect(fixture.model.history.count == 1)
        #expect(try fixture.backupCount() == 1)
        let written = try fixture.decoded()
        #expect((written["sandbox"] as? NSDictionary)?["enabled"] as? Bool == true)
        #expect((written["env"] as? NSDictionary)?["DISABLE_TELEMETRY"] as? String == "1")
        #expect(written["preferredNotifChannel"] as? String == "notifications_disabled")
    }

    @Test func confirmationLinesGateApply() async throws {
        let fixture = try await ModelFixture.make("{}\n")
        let onboarding = try start(fixture)
        answer(onboarding, ["privacy": "less"])
        #expect(onboarding.lines.first { $0.id == "DISABLE_TELEMETRY" }?.needsConfirm == true)

        await onboarding.apply()
        #expect(onboarding.confirmRequest?.tweakId == "DISABLE_TELEMETRY")
        #expect(try fixture.text() == "{}\n")

        onboarding.cancelConfirmation()
        #expect(onboarding.confirmRequest == nil)
        #expect(fixture.model.onboarding != nil)
        #expect(try fixture.text() == "{}\n")
        #expect(!fixture.model.canUndo)

        await onboarding.apply()
        await onboarding.confirm()
        #expect(onboarding.confirmRequest == nil)
        #expect((try fixture.decoded()["env"] as? NSDictionary)?["DISABLE_TELEMETRY"] as? String == "1")
        #expect(fixture.model.onboarding == nil)
    }

    @Test func untickingSandboxDropsItsDependents() async throws {
        let questions = OnboardingFile(questions: [
            OnboardingFile.Question(
                id: "safety", title: "How strict?",
                options: [
                    OnboardingFile.Option(
                        id: "strict", label: "Strict", profile: .cautious,
                        sets: [
                            OnboardingFile.Assignment(tweakId: "sandbox.enabled", value: true),
                            OnboardingFile.Assignment(tweakId: "sandbox.failIfUnavailable", value: true),
                        ]),
                    OnboardingFile.Option(id: "keep", label: "Keep", profile: .balanced, sets: []),
                ])
        ])
        #expect(OnboardingLinter.lint(questions, catalog: sandboxCatalog).isEmpty)
        let onboarding = try start(try await ModelFixture.make(catalog: sandboxCatalog, setupQuestions: questions))
        answer(onboarding, ["safety": "strict"])
        #expect(onboarding.lines.map(\.id) == ["sandbox.enabled", "sandbox.failIfUnavailable"])

        onboarding.setTicked(false, tweakId: "sandbox.enabled")
        let dependent = try #require(onboarding.lines.first { $0.id == "sandbox.failIfUnavailable" })
        #expect(!dependent.isTicked)
        #expect(dependent.removedBecause == "Needs the sandbox on.")
        #expect(onboarding.acceptance?.changes.isEmpty == true)
        #expect(!onboarding.canApply)

        onboarding.setTicked(true, tweakId: "sandbox.enabled")
        #expect(onboarding.acceptance?.changes.count == 2)
        #expect(onboarding.lines.allSatisfy { $0.isTicked && $0.removedBecause == nil })
    }

    @Test func untickingFocusDropsItsFullscreenAddition() async throws {
        let onboarding = try start(try await ModelFixture.make("{}\n"))
        answer(onboarding, ["sessions": "many"])
        let addition = try #require(onboarding.lines.first { $0.id == "tui" })
        #expect(addition.isDependency)
        #expect(addition.summary == "Also turning on Renderer (Fullscreen) because focus view needs the fullscreen renderer.")

        onboarding.setTicked(false, tweakId: "viewMode")
        let dropped = try #require(onboarding.lines.first { $0.id == "tui" })
        #expect(!dropped.isTicked)
        #expect(dropped.removedBecause?.contains("Starting view") == true)
        #expect(onboarding.acceptance?.changes.map(\.tweakId) == ["awaySummaryEnabled"])
        #expect(!onboarding.diff.contains { $0.text.contains("\"tui\"") })

        onboarding.setTicked(true, tweakId: "viewMode")
        let restored = try #require(onboarding.lines.first { $0.id == "tui" })
        #expect(restored.isTicked)
        #expect(restored.removedBecause == nil)
        #expect(restored.summary == addition.summary)
        #expect(onboarding.acceptance?.changes.map(\.tweakId).contains("tui") == true)
        #expect(onboarding.diff.contains { $0.kind == .added && $0.text.contains("\"tui\": \"fullscreen\"") })
    }

    @Test func valueAlreadyInFileShowsNothing() async throws {
        let onboarding = try start(try await ModelFixture.make("{\n  \"preferredNotifChannel\": \"terminal_bell\"\n}\n"))
        answer(onboarding, ["notifications": "bell"])
        #expect(onboarding.proposal?.isEmpty == true)
        #expect(onboarding.proposal?.alreadySet.map(\.tweakId) == ["preferredNotifChannel"])
        #expect(onboarding.lines.isEmpty)
        #expect(!onboarding.canApply)
    }

    @Test func undoOfOnboardingGroupKeepsOutsideEdit() async throws {
        let fixture = try await ModelFixture.make("{\n  \"model\": \"opus\"\n}\n")
        let onboarding = try start(fixture)
        answer(onboarding, Self.cautious)
        await onboarding.apply()
        while onboarding.confirmRequest != nil {
            await onboarding.confirm()
        }
        #expect(fixture.model.user.undoLog.entries.count == 1)
        try fixture.write(try fixture.text().replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))

        await fixture.model.undo()
        #expect(fixture.model.blockedUndo == nil)
        #expect(try fixture.decoded() == ["model": "sonnet"])
    }

    @Test func firstLaunchOpensQuestionsOnceWithAStore() async throws {
        let flags = MemoryOnboardingFlags()
        let first = try await ModelFixture.make(launchFlags: flags)
        first.model.presentOnboardingIfFirstLaunch()
        #expect(first.model.onboarding != nil)
        first.model.finishOnboarding()
        #expect(flags.onboardingSeen)

        let second = try await ModelFixture.make(launchFlags: flags)
        second.model.presentOnboardingIfFirstLaunch()
        #expect(second.model.onboarding == nil)

        let withoutStore = try await ModelFixture.make()
        withoutStore.model.presentOnboardingIfFirstLaunch()
        #expect(withoutStore.model.onboarding == nil)
    }

    @Test func flagStoreIsOffForCustomPathAndTestRuns() async throws {
        let suite = "PitotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(OnboardingFlags.store(mode: .custom, environment: [:], defaults: defaults) == nil)
        #expect(OnboardingFlags.store(mode: .copy, environment: ["XCTestConfigurationFilePath": "/x"], defaults: defaults) == nil)
        #expect(OnboardingFlags.store(mode: .copy, environment: ProcessInfo.processInfo.environment, defaults: defaults) == nil)

        let store = try #require(OnboardingFlags.store(mode: .real, environment: [:], defaults: defaults))
        #expect(!store.onboardingSeen)
        store.onboardingSeen = true
        #expect(defaults.bool(forKey: UserDefaultsOnboardingFlags.key))
    }
}
