import Foundation
import Testing

@testable import PitotCore

@Suite("Onboarding models")
struct OnboardingModelsTests {
    private static let sample = #"""
        {
          "questions": [
            {
              "id": "cost",
              "title": "How much does cost matter to you?",
              "hint": "Helper models and effort.",
              "options": [
                {
                  "id": "low",
                  "label": "Keep costs low.",
                  "hint": "Helpers use Haiku.",
                  "profile": "cautious",
                  "sets": [
                    { "tweakId": "CLAUDE_CODE_SUBAGENT_MODEL", "value": "haiku" },
                    { "tweakId": "maxEffortLevel", "value": null },
                    { "tweakId": "cleanupPeriodDays", "value": 30 }
                  ]
                },
                {
                  "id": "keep",
                  "label": "Keep my settings.",
                  "profile": "balanced",
                  "sets": []
                }
              ]
            }
          ]
        }
        """#

    private func decode(_ text: String) throws(OnboardingError) -> OnboardingFile {
        try OnboardingLoader.decode(data: Data(text.utf8))
    }

    @Test func decodesASample() throws {
        let file = try decode(Self.sample)

        let question = try #require(file.questions.first)
        #expect(question.id == "cost")
        #expect(question.hint == "Helper models and effort.")
        #expect(question.options.map(\.id) == ["low", "keep"])
        let low = try #require(question.option(id: "low"))
        #expect(low.profile == .cautious)
        #expect(low.hint == "Helpers use Haiku.")
        #expect(
            low.sets == [
                OnboardingFile.Assignment(tweakId: "CLAUDE_CODE_SUBAGENT_MODEL", value: "haiku"),
                OnboardingFile.Assignment(tweakId: "maxEffortLevel", value: nil),
                OnboardingFile.Assignment(tweakId: "cleanupPeriodDays", value: 30),
            ])
        #expect(question.option(id: "keep")?.sets == [])
        #expect(question.option(id: "keep")?.hint == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let file = try decode(Self.sample)

        let data = try JSONEncoder().encode(file)

        #expect(try OnboardingLoader.decode(data: data) == file)
    }

    @Test func nullIsEncodedNotDropped() throws {
        let assignment = OnboardingFile.Assignment(tweakId: "maxEffortLevel", value: nil)

        let text = String(decoding: try JSONEncoder().encode(assignment), as: UTF8.self)

        #expect(text.contains(#""value":null"#))
    }

    @Test func missingValueIsRejectedSoNullMustBeExplicit() {
        let text = #"{"questions": [{"id": "q", "title": "Q?", "options": [{"id": "a", "label": "A.", "profile": "power", "sets": [{"tweakId": "tui"}]}]}]}"#

        #expect(throws: OnboardingError.malformed(path: "questions[0].options[0].sets[0].value", reason: #"Missing key "value""#)) {
            try decode(text)
        }
    }

    @Test("unknown keys are rejected at every level", arguments: [
        (#"{"questions": [], "extra": 1}"#, "extra"),
        (#"{"questions": [{"id": "q", "title": "Q?", "options": [], "extra": 1}]}"#, "questions[0].extra"),
        (
            #"{"questions": [{"id": "q", "title": "Q?", "options": [{"id": "a", "label": "A.", "profile": "power", "sets": [], "set": []}]}]}"#,
            "questions[0].options[0].set"
        ),
        (
            #"""
            {"questions": [{"id": "q", "title": "Q?", "options": [{"id": "a", "label": "A.", "profile": "power",
              "sets": [{"tweakId": "t", "value": 1, "x": 2}]}]}]}
            """#,
            "questions[0].options[0].sets[0].x"
        ),
    ])
    func unknownKeysAreRejected(text: String, path: String) {
        let key = path.split(separator: ".").last.map(String.init) ?? path

        #expect(throws: OnboardingError.malformed(path: path, reason: "Unknown key \"\(key)\"")) {
            try decode(text)
        }
    }

    @Test func unknownProfileIsRejected() {
        let text = #"{"questions": [{"id": "q", "title": "Q?", "options": [{"id": "a", "label": "A.", "profile": "reckless", "sets": []}]}]}"#

        #expect(throws: OnboardingError.self) { try decode(text) }
    }

    @Test func profileTitlesArePlainWords() {
        #expect(OnboardingFile.Profile.allCases.map(\.title) == ["Cautious", "Balanced", "Power user"])
    }
}
