import Foundation
import Testing

@testable import PitotCore

@Suite("Onboarding safety")
struct OnboardingSafetyTests {
    private typealias Samples = OnboardingSamples

    /// Holds risky values, keys Pitot does not know, and env values that must survive.
    static let riskyDocument = #"""
        {
          "model": "opus",
          "tui": "default",
          "viewMode": "verbose",
          "maxEffortLevel": "low",
          "skipDangerousModePermissionPrompt": true,
          "permissions": {
            "allow": ["Bash(git status)"],
            "defaultMode": "bypassPermissions"
          },
          "sandbox": { "enabled": false, "network": { "allowLocalBinding": true } },
          "hooks": { "Stop": [] },
          "futureKey": { "nested": [1, 2e3, "x"], "n": 1.50 },
          "env": {
            "ANTHROPIC_BASE_URL": "https://proxy.example.com",
            "DISABLE_TELEMETRY": "0",
            "CLAUDE_CODE_SUBAGENT_MODEL": "opus",
            "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1",
            "CUSTOM_VAR": "keep me"
          }
        }
        """#

    /// Already holds many onboarding values.
    static let tunedDocument = #"""
        {
          "tui": "fullscreen",
          "viewMode": "focus",
          "sandbox": { "enabled": true },
          "permissions": { "disableBypassPermissionsMode": "disable", "defaultMode": "plan" },
          "env": { "CLAUDE_CODE_NEW_INIT": "1", "DISABLE_TELEMETRY": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "haiku" }
        }
        """#

    /// Parents that are not objects, so some edits cannot apply.
    static let oddDocument = #"{"sandbox": true, "env": "not an object", "permissions": [], "outputStyle": 3, "tui": null}"#

    static let documentTexts = ["{}", riskyDocument, tunedDocument, oddDocument]

    let catalog: Catalog
    let file: OnboardingFile
    let audit: SafetyAudit
    let documents: [JSONDocument]
    let versions: [ClaudeVersion?]

    init() throws {
        catalog = try Samples.realCatalog()
        file = try Samples.realFile(catalog: catalog)
        audit = SafetyAudit(catalog: catalog, file: file)
        documents = try Self.documentTexts.map(Samples.document)
        versions = [nil, try Samples.version("2.1.200"), try Samples.version(catalog.claudeCodeVersionChecked)]
    }

    private func check(_ answers: [String: String], document index: Int, installed: ClaudeVersion?) -> [String] {
        let proposal = Onboarding.propose(file, answers: answers, catalog: catalog, document: documents[index], installed: installed)
        let label = answers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let place = "[\(label)] doc \(index) v\(installed?.description ?? "nil")"
        return audit.violations(proposal, answers: answers, document: documents[index]).map { "\(place): \($0)" }
    }

    private func report(_ violations: [String]) -> Comment {
        Comment(rawValue: "\(violations.count) violations, first ones:\n" + violations.prefix(15).joined(separator: "\n"))
    }

    @Test func everyOptionAloneIsSafe() {
        var violations: [String] = []
        var checked = 0
        for index in documents.indices {
            for installed in versions {
                for question in file.questions {
                    for option in question.options {
                        violations += check([question.id: option.id], document: index, installed: installed)
                        checked += 1
                    }
                }
            }
        }

        #expect(checked == documents.count * versions.count * file.questions.reduce(0) { $0 + $1.options.count })
        #expect(violations.isEmpty, report(violations))
    }

    @Test func everyCombinationOfOneOptionPerQuestionIsSafe() {
        let counts = file.questions.map(\.options.count)
        let total = counts.reduce(1, *)
        var violations: [String] = []
        for combination in 0..<total {
            var rest = combination
            var answers: [String: String] = [:]
            for question in file.questions {
                answers[question.id] = question.options[rest % question.options.count].id
                rest /= question.options.count
            }
            let index = combination % 2
            violations += check(answers, document: index, installed: versions[2])
        }

        #expect(total >= 2000)
        #expect(violations.isEmpty, report(violations))
    }

    @Test func randomAnswersOnEveryDocumentAndVersionAreSafe() {
        var generator = SplitMix64(seed: 0xC0C_4917)
        var violations: [String] = []
        for round in 0..<2000 {
            var answers: [String: String] = [:]
            for question in file.questions {
                let pick = Int.random(in: 0...question.options.count, using: &generator)
                if pick < question.options.count { answers[question.id] = question.options[pick].id }
            }
            violations += check(answers, document: round % documents.count, installed: versions[round % versions.count])
        }

        #expect(violations.isEmpty, report(violations))
    }

    @Test func noOptionInTheFileWritesAForbiddenValue() throws {
        for question in file.questions {
            for option in question.options {
                for assignment in option.sets {
                    let tweak = try #require(catalog.tweak(id: assignment.tweakId))
                    let operation = tweak.operation(for: assignment.value)
                    #expect(SafetyAudit.forbiddenWrite(operation) == [], "\(question.id).\(option.id) sets \(assignment.tweakId)")
                    #expect(OnboardingSafety.violation(tweak, value: assignment.value) == nil)
                }
            }
        }
    }

    /// Forcing one subagent model is left to the main screen. Kept without a subagent model,
    /// it forces the main conversation's model onto every subagent, which costs more.
    @Test func noOptionSetsTheForcedSubagentModel() {
        for question in file.questions {
            for option in question.options {
                #expect(!option.sets.contains { $0.tweakId == "CLAUDE_CODE_SUBAGENT_MODEL_FORCE" }, "\(question.id).\(option.id)")
            }
        }
    }

    // MARK: The rule table in Core

    @Test("the rule table forbids", arguments: [
        ("permissions.defaultMode", TweakValue?.some("bypassPermissions")),
        ("permissions.defaultMode", "auto"),
        ("sandbox.enabled", false),
        ("sandbox.enabled", nil),
        ("permissions.blockReadsOutsideWorkingDirectories", false),
        ("permissions.blockReadsOutsideWorkingDirectories", nil),
        ("permissions.disableBypassPermissionsMode", false),
        ("permissions.disableBypassPermissionsMode", nil),
        ("ANTHROPIC_BASE_URL", "https://proxy.example.com"),
        ("ANTHROPIC_BASE_URL", nil),
    ])
    func ruleTableForbids(id: String, value: TweakValue?) throws {
        let tweak = try #require(catalog.tweak(id: id))

        #expect(OnboardingSafety.violation(tweak, value: value) != nil)
    }

    @Test("the rule table allows", arguments: [
        ("permissions.defaultMode", TweakValue?.some("acceptEdits")),
        ("permissions.defaultMode", "default"),
        ("permissions.defaultMode", nil),
        ("sandbox.enabled", true),
        ("permissions.blockReadsOutsideWorkingDirectories", true),
        ("permissions.disableBypassPermissionsMode", true),
        ("DISABLE_TELEMETRY", true),
        ("DISABLE_TELEMETRY", false),
    ])
    func ruleTableAllows(id: String, value: TweakValue?) throws {
        let tweak = try #require(catalog.tweak(id: id))

        #expect(OnboardingSafety.violation(tweak, value: value) == nil)
    }

    @Test func rulesFollowTheFilePathNotTheTweakId() {
        let renamed = Samples.tweak("sandboxOn", location: .setting(path: ["sandbox", "enabled"]))
        let skip = Samples.tweak("skipWarning", location: .setting(path: ["skipDangerousModePermissionPrompt"]))

        #expect(OnboardingSafety.violation(renamed, value: false) != nil)
        #expect(OnboardingSafety.violation(skip, value: true) != nil)
        #expect(OnboardingSafety.violation(skip, value: nil) != nil)
    }

    @Test func proposeBlocksForbiddenValuesEvenWithoutTheLint() throws {
        let unlinted = OnboardingFile(questions: [
            Samples.question(
                "danger",
                Samples.option(
                    "a", .power,
                    [("sandbox.enabled", false), ("permissions.defaultMode", "bypassPermissions"), ("ANTHROPIC_BASE_URL", "https://x.example")]),
                Samples.option("b"))
        ])
        let document = try Samples.document(#"{"sandbox": {"enabled": true}}"#)

        let proposal = Onboarding.propose(unlinted, answers: ["danger": "a"], catalog: catalog, document: document, installed: versions[2])

        #expect(proposal.all.isEmpty)
        #expect(proposal.blocked.map(\.tweakId) == ["sandbox.enabled", "permissions.defaultMode", "ANTHROPIC_BASE_URL"])
        #expect(proposal.blocked.allSatisfy { $0.reason.hasPrefix("Onboarding never") })
    }
}
