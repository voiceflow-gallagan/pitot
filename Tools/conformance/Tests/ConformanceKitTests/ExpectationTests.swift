import PitotCore
import Foundation
import Testing

@testable import ConformanceKit

/// The expected side, without Claude Code: what `EffectiveSettings` gives for each case must match
/// what the test runs behind `Core/MERGE-RULES.md` saw.
@Suite("Expected values")
struct ExpectationTests {
    struct Documented: Sendable, CustomStringConvertible {
        let caseID: String
        let check: Check
        let value: String

        init(_ caseID: String, _ check: Check, _ value: String) {
            self.caseID = caseID
            self.check = check
            self.value = value
        }

        var description: String { "\(caseID) \(check)" }
    }

    static let projectStart = HookProbe(.project, "SessionStart")
    static let localStart = HookProbe(.local, "SessionStart")

    static let documented: [Documented] = [
        Documented("env-local-wins", .env(Catalog.variable(1)), "local"),
        Documented("env-per-variable", .env(Catalog.variable(2)), "project"),
        Documented("env-per-variable", .env(Catalog.variable(3)), "local"),
        Documented("env-null-text", .env(Catalog.variable(4)), "null"),
        Documented("env-null-text", .hook(localStart), Outcome.ran),
        Documented("scalar-local-wins", .initField(.outputStyle), "Learning"),
        Documented("nested-object-merge", .initField(.permissionMode), "acceptEdits"),
        Documented("hooks-join", .hook(projectStart), Outcome.ran),
        Documented("hooks-join", .hook(localStart), Outcome.ran),
        Documented("hooks-per-event", .hook(HookProbe(.project, "UserPromptSubmit")), Outcome.ran),
        Documented("env-empty-object", .env(Catalog.variable(5)), "project"),
        Documented("env-empty-object", .hook(localStart), Outcome.ran),
        Documented("typed-null-drops-file", .env(Catalog.variable(6)), "project"),
        Documented("typed-null-drops-file", .env(Catalog.variable(7)), Outcome.unset),
        Documented("typed-null-drops-file", .hook(localStart), Outcome.didNotRun),
        Documented("typed-null-drops-file", .initField(.outputStyle), "Explanatory"),
        Documented("object-null-drops-file", .env(Catalog.variable(8)), Outcome.unset),
        Documented("object-null-drops-file", .env(Catalog.variable(9)), "local"),
        Documented("object-null-drops-file", .hook(projectStart), Outcome.didNotRun),
        Documented("object-null-drops-file", .initField(.outputStyle), InitField.unsetText),
    ]

    static func expected(_ caseID: String, mutate: Bool = false) throws -> [(check: Check, text: String)] {
        let batch = try #require(Catalog.batches.first { $0.cases.contains { $0.id == caseID } })
        let conformanceCase = try #require(batch.cases.first { $0.id == caseID })
        let plan = BatchPlan(batch: batch, workDirectory: URL(fileURLWithPath: "/tmp/conformance-test", isDirectory: true))
        return Expectation(plan: plan).expected(for: conformanceCase, mutate: mutate)
    }

    @Test(arguments: documented)
    func pitotMatchesTheResearchRuns(_ row: Documented) throws {
        let found = try #require(try Self.expected(row.caseID).first { $0.check == row.check })
        #expect(found.text == row.value)
    }

    @Test func everyCheckHasADocumentedValue() {
        let documented = Set(Self.documented.map(\.description))
        let checks = Catalog.cases.flatMap { conformanceCase in conformanceCase.checks.map { "\(conformanceCase.id) \($0)" } }
        #expect(Set(checks) == documented)
        #expect(checks.count == Self.documented.count)
    }

    @Test func pitotRejectsTheFilesWithANullTypedKey() throws {
        let typedNull = try #require(Catalog.batches.first { $0.name == "typed-null" })
        let objectNull = try #require(Catalog.batches.first { $0.name == "object-null" })
        let directory = URL(fileURLWithPath: "/tmp/conformance-test", isDirectory: true)
        let local = BatchPlan(batch: typedNull, workDirectory: directory).layers().first { $0.id == .local }
        let project = BatchPlan(batch: objectNull, workDirectory: directory).layers().first { $0.id == .project }
        #expect(local?.state == .invalid(.nullValue(path: ["outputStyle"])))
        #expect(project?.state == .invalid(.nullValue(path: ["permissions"])))
    }

    @Test func mutationFlipsOnlyTheTargetToTheLowerLayer() throws {
        for conformanceCase in Catalog.cases {
            let plain = try Self.expected(conformanceCase.id)
            let mutated = try Self.expected(conformanceCase.id, mutate: true)
            let changed = zip(plain, mutated).filter { $0.text != $1.text }
            if conformanceCase.id == Catalog.mutationTarget.caseID {
                #expect(changed.map(\.0.check) == [Catalog.mutationTarget.check])
                #expect(changed.map(\.1.text) == ["project"])
            } else {
                #expect(changed.isEmpty, "\(conformanceCase.id)")
            }
        }
    }
}
