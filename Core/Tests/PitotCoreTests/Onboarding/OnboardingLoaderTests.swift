import Foundation
import Testing

@testable import PitotCore

@Suite("Onboarding loader")
struct OnboardingLoaderTests {
    private typealias Samples = OnboardingSamples

    private let catalog = Samples.catalog([
        Samples.tweak("quiet", location: .env(name: "QUIET_MODE"), valueType: .flag),
        Samples.tweak(
            "mode", location: .setting(path: ["permissions", "defaultMode"]),
            valueType: .enumeration([.init(value: "default", label: "Default"), .init(value: "bypassPermissions", label: "Bypass")])),
        Samples.tweak("box", location: .setting(path: ["sandbox", "enabled"])),
        Samples.tweak("count", valueType: .integer(min: 1, max: 10)),
    ])

    private func rules(_ questions: OnboardingFile.Question...) -> [OnboardingLintIssue.Rule] {
        OnboardingLinter.lint(OnboardingFile(questions: questions), catalog: catalog).map(\.rule)
    }

    private func pair(_ sets: [(String, TweakValue?)]) -> OnboardingFile.Question {
        Samples.question("q", Samples.option("a", .balanced, sets), Samples.option("b"))
    }

    @Test func cleanFileHasNoIssues() {
        #expect(rules(pair([("quiet", true), ("mode", "default"), ("box", true), ("count", 3)])) == [])
    }

    @Test func fileWithoutQuestionsFails() {
        #expect(rules() == [.noQuestions])
    }

    @Test func questionIdsAreUnique() {
        #expect(rules(pair([]), pair([])) == [.duplicateQuestionId])
    }

    @Test func optionIdsAreUniqueWithinAQuestion() {
        #expect(rules(Samples.question("q", Samples.option("a"), Samples.option("a"))) == [.duplicateOptionId])
        #expect(rules(Samples.question("q", Samples.option("a"), Samples.option("b")), Samples.question("r", Samples.option("a"), Samples.option("b"))) == [])
    }

    @Test("a question has 2 to 4 options", arguments: [1, 5])
    func optionCountIsLimited(count: Int) {
        let options = (0..<count).map { Samples.option("o\($0)") }

        #expect(rules(OnboardingFile.Question(id: "q", title: "Q?", options: options)) == [.optionCount])
    }

    @Test func textMustNotBeEmpty() {
        let question = OnboardingFile.Question(
            id: "q", title: " ",
            options: [OnboardingFile.Option(id: "a", label: "", profile: .power, sets: []), Samples.option("b")])

        #expect(rules(question) == [.emptyText, .emptyText])
    }

    @Test func everyTweakMustBeInTheCatalog() {
        #expect(rules(pair([("nope", true)])) == [.unknownTweak])
    }

    @Test func anOptionSetsATweakOnce() {
        #expect(rules(pair([("count", 2), ("count", 3)])) == [.duplicateTweak])
    }

    @Test(
        "values must pass the validator",
        arguments: [("count", TweakValue.integer(0)), ("count", .string("3")), ("quiet", .string("0")), ("mode", .string("plan"))])
    func valuesAreValidated(id: String, value: TweakValue) {
        #expect(rules(pair([(id, value)])) == [.invalidValue])
    }

    @Test func removingAKeyNeedsNoValidation() {
        #expect(rules(pair([("count", nil), ("quiet", nil)])) == [])
    }

    @Test("forbidden values fail the lint", arguments: [("mode", TweakValue?.some("bypassPermissions")), ("box", false), ("box", nil)])
    func forbiddenValuesFail(id: String, value: TweakValue?) {
        #expect(rules(pair([(id, value)])) == [.forbiddenValue])
    }

    @Test func loadRejectsALintFailure() throws {
        let text = #"""
            {"questions": [{"id": "q", "title": "Q?", "options": [{"id": "a", "label": "A.", "profile": "power",
              "sets": [{"tweakId": "box", "value": false}]}]}]}
            """#
        let file = try OnboardingLoader.decode(data: Data(text.utf8))

        #expect(throws: OnboardingError.lintFailed(OnboardingLinter.lint(file, catalog: catalog))) {
            try OnboardingLoader.load(data: Data(text.utf8), catalog: catalog)
        }
        #expect(Set(OnboardingLinter.lint(file, catalog: catalog).map(\.rule)) == [.optionCount, .forbiddenValue])
    }

    @Test func issuesNameTheQuestionAndOption() {
        let issue = OnboardingLinter.lint(OnboardingFile(questions: [pair([("nope", true)])]), catalog: catalog).first

        #expect(issue?.questionId == "q")
        #expect(issue?.optionId == "a")
        #expect(issue?.description.hasPrefix("q.a: ") == true)
    }

    @Test func malformedJSONNamesThePath() {
        let text = #"{"questions": [{"id": "q", "title": "Q?", "options": [{"id": 3}]}]}"#

        let error = #expect(throws: OnboardingError.self) {
            try OnboardingLoader.decode(data: Data(text.utf8))
        }

        guard case .malformed(let path, _) = error else {
            Issue.record("Expected a malformed error, got \(String(describing: error))")
            return
        }
        #expect(path == "questions[0].options[0].id")
    }
}
