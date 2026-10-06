import Foundation
import Testing

@testable import PitotCore

@Suite("Onboarding data")
struct OnboardingDataTests {
    private typealias Samples = OnboardingSamples

    static let cautious = [
        "experience": "new", "privacy": "least", "cost": "lowest", "work": "learn", "autonomy": "ask", "sessions": "one", "notifications": "off",
    ]
    static let balanced = [
        "experience": "weeks", "privacy": "default", "cost": "some", "work": "plan", "autonomy": "sandbox", "sessions": "few", "notifications": "auto",
    ]
    static let power = [
        "experience": "daily", "privacy": "default", "cost": "quality", "work": "quick", "autonomy": "edits", "sessions": "many", "notifications": "bell",
    ]

    let catalog: Catalog
    let file: OnboardingFile
    let latest: ClaudeVersion

    init() throws {
        catalog = try Samples.realCatalog()
        file = try Samples.realFile(catalog: catalog)
        latest = try Samples.version(catalog.claudeCodeVersionChecked)
    }

    private func propose(_ answers: [String: String], document text: String = "{}", installed: ClaudeVersion?? = .none) throws -> Proposal {
        Onboarding.propose(file, answers: answers, catalog: catalog, document: try Samples.document(text), installed: installed ?? latest)
    }

    // MARK: Shape of the file

    @Test func theFileHasTheSevenQuestionsInOrder() {
        #expect(file.questions.map(\.id) == ["experience", "privacy", "cost", "work", "autonomy", "sessions", "notifications"])
        #expect(file.questions.allSatisfy { OnboardingLinter.optionRange.contains($0.options.count) })
    }

    @Test func textIsShortAndPlain() {
        var texts: [String] = []
        for question in file.questions {
            texts += [question.title] + [question.hint].compactMap { $0 }
            for option in question.options {
                texts += [option.label] + [option.hint].compactMap { $0 }
            }
        }
        for text in texts {
            let words = text.split(whereSeparator: \.isWhitespace).count
            #expect(words <= 15, "\(words) words: \(text)")
            #expect(text.allSatisfy { $0.isASCII && !$0.isNewline }, "not plain ASCII: \(text)")
            #expect(!text.contains("--") && !text.contains(";"), "dash or semicolon: \(text)")
        }
    }

    @Test func everyProfileIsOfferedAndEveryQuestionCanKeepOrChange() {
        let profiles = Set(file.questions.flatMap { $0.options.map(\.profile) })

        #expect(profiles == Set(OnboardingFile.Profile.allCases))
        #expect(file.questions.allSatisfy { question in question.options.contains { !$0.sets.isEmpty } })
    }

    @Test func eachPresetPathPicksOneOptionPerQuestion() {
        for path in [Self.cautious, Self.balanced, Self.power] {
            #expect(Set(path.keys) == Set(file.questions.map(\.id)))
            #expect(path.allSatisfy { file.question(id: $0.key)?.option(id: $0.value) != nil })
        }
    }

    @Test func opusplanIsNotOfferedWhileTheCatalogSaysItIsUntested() throws {
        let model = try #require(catalog.tweak(id: "model"))
        let setsModel = file.questions.contains { $0.options.contains { $0.sets.contains { $0.tweakId == "model" } } }

        #expect(!setsModel || model.notes?.contains("still to be tested") == false)
    }

    // MARK: Preset paths

    @Test func cautiousPath() throws {
        let proposal = try propose(Self.cautious)

        #expect(
            Samples.lines(proposal.changes) == [
                "CLAUDE_CODE_NEW_INIT=true",
                "DISABLE_TELEMETRY=true",
                "DISABLE_ERROR_REPORTING=true",
                "disableClaudeAiConnectors=true",
                "CLAUDE_CODE_SUBAGENT_MODEL=haiku",
                "maxEffortLevel=medium",
                "promptCacheTtl=5m",
                "autoCompactEnabled=true",
                "outputStyle=Explanatory",
                "sandbox.enabled=true",
                "permissions.blockReadsOutsideWorkingDirectories=true",
                "permissions.disableBypassPermissionsMode=true",
                "preferredNotifChannel=notifications_disabled",
            ])
        #expect(proposal.dependencyAdditions.isEmpty)
        #expect(proposal.alreadySet.isEmpty && proposal.skipped.isEmpty && proposal.blocked.isEmpty)
        #expect(proposal.presetLabel == .cautious)
        #expect(proposal.confirmations.map(\.tweakId) == ["DISABLE_TELEMETRY"])
        #expect(proposal.changes.first { $0.tweakId == "permissions.disableBypassPermissionsMode" }?.operation
            == .set(path: ["permissions", "disableBypassPermissionsMode"], value: .json("disable")))
        #expect(proposal.changes.first { $0.tweakId == "DISABLE_TELEMETRY" }?.operation == .set(path: ["env", "DISABLE_TELEMETRY"], value: .json("1")))
    }

    @Test func balancedPath() throws {
        let proposal = try propose(Self.balanced)

        #expect(
            Samples.lines(proposal.changes) == [
                "CLAUDE_CODE_NEW_INIT=true",
                "showThinkingSummaries=true",
                "CLAUDE_CODE_SUBAGENT_MODEL=sonnet",
                "maxEffortLevel=high",
                "autoCompactEnabled=true",
                "plansDirectory=.claude/plans",
                "showClearContextOnPlanAccept=true",
                "sandbox.enabled=true",
                "tui=fullscreen",
                "awaySummaryEnabled=true",
                "preferredNotifChannel=auto",
            ])
        #expect(proposal.dependencyAdditions.isEmpty)
        #expect(proposal.presetLabel == .balanced)
        #expect(proposal.confirmations.isEmpty)
    }

    @Test func powerPath() throws {
        let proposal = try propose(Self.power)

        #expect(
            Samples.lines(proposal.changes) == [
                "showThinkingSummaries=true",
                "promptSuggestionEnabled=false",
                "promptCacheTtl=1h",
                "outputStyle=Concise",
                "sandbox.enabled=true",
                "permissions.defaultMode=acceptEdits",
                "viewMode=focus",
                "awaySummaryEnabled=true",
                "preferredNotifChannel=terminal_bell",
            ])
        #expect(Samples.lines(proposal.dependencyAdditions) == ["tui=fullscreen"])
        #expect(proposal.dependencyAdditions.first?.reason == "Focus view needs the fullscreen renderer.")
        #expect(proposal.dependencyAdditions.first?.source == .dependency(requiredBy: ["viewMode"]))
        #expect(Samples.lines(proposal.alreadySet) == ["CLAUDE_CODE_SUBAGENT_MODEL=unset", "maxEffortLevel=unset"])
        #expect(proposal.presetLabel == .power)
        #expect(proposal.confirmations.isEmpty)
    }

    @Test func powerPathRemovesCapsTheFileHolds() throws {
        let document = #"""
            {"maxEffortLevel": "low", "tui": "fullscreen", "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "haiku", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"}}
            """#

        let proposal = try propose(Self.power, document: document)

        #expect(
            Array(Samples.lines(proposal.changes)[2..<5]) == [
                "CLAUDE_CODE_SUBAGENT_MODEL=unset", "maxEffortLevel=unset", "promptCacheTtl=1h",
            ])
        #expect(proposal.dependencyAdditions.isEmpty)
        #expect(
            proposal.operations.filter { if case .remove = $0 { true } else { false } } == [
                .remove(path: ["env", "CLAUDE_CODE_SUBAGENT_MODEL"]),
                .remove(path: ["maxEffortLevel"]),
            ])
        #expect(!proposal.operations.contains { $0.path == ["env", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] })
    }

    // MARK: Versions and repeat runs on the real data

    @Test func anOlderClaudeCodeSkipsNewerTweaks() throws {
        let proposal = try propose(Self.cautious, installed: try Samples.version("2.1.200"))

        #expect(
            Samples.lines(proposal.skipped) == [
                "maxEffortLevel=medium", "promptCacheTtl=5m", "permissions.blockReadsOutsideWorkingDirectories=true",
            ])
        #expect(proposal.skipped.allSatisfy { $0.reason.hasPrefix("Needs Claude Code 2.1.2") && $0.reason.hasSuffix("You have 2.1.200.") })
        #expect(proposal.changes.count == 10)
    }

    @Test func anUnknownVersionKeepsEveryChangeAndWarns() throws {
        let proposal = try propose(Self.cautious, installed: .some(nil))

        #expect(proposal.changes.count == 13)
        #expect(proposal.skipped.isEmpty)
        #expect(proposal.unverifiedVersion == [
            "maxEffortLevel", "promptCacheTtl", "permissions.blockReadsOutsideWorkingDirectories",
        ])
        #expect(proposal.warnings.contains { $0.hasPrefix("Pitot could not read your Claude Code version.") })
    }

    @Test("a file that already holds every value gets an empty proposal", arguments: [cautious, balanced, power])
    func secondRunIsEmpty(answers: [String: String]) throws {
        let first = try propose(answers, document: OnboardingSafetyTests.riskyDocument)
        var bytes = try Samples.document(OnboardingSafetyTests.riskyDocument).bytes
        for operation in first.operations {
            bytes = try JSONEdit.apply(operation, to: bytes).bytes
        }

        let second = Onboarding.propose(file, answers: answers, catalog: catalog, document: try JSONScanner.scan(bytes), installed: latest)

        #expect(!first.isEmpty)
        #expect(second.isEmpty)
        #expect(second.alreadySet.count == first.changes.count + first.alreadySet.count)
    }
}
