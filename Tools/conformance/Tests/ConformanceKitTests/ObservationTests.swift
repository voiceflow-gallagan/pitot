import PitotCore
import Foundation
import Testing

@testable import ConformanceKit

@Suite("Observed values")
struct ObservationTests {
    static let projectStart = HookProbe(.project, "SessionStart")
    static let localStart = HookProbe(.local, "SessionStart")

    @Test func parsesAnEnvDump() {
        let dump = "PITOT_CONF_1=local\nPITOT_CONF_2=a=b\nPITOT_CONF_3=\n"
        #expect(Observation.environment(fromDump: dump) == ["PITOT_CONF_1": "local", "PITOT_CONF_2": "a=b", "PITOT_CONF_3": ""])
    }

    @Test func readsInitFieldsAndCostFromTheStream() {
        let stream = """
            {"type":"system","subtype":"hook_started"}
            not json
            {"type":"system","subtype":"init","output_style":"Learning","permissionMode":"acceptEdits","tools":[]}
            {"type":"result","subtype":"success","total_cost_usd":0.0285}

            """
        var observation = Observation()
        observation.readStream(Array(stream.utf8))
        #expect(observation.initFields == [.outputStyle: "Learning", .permissionMode: "acceptEdits"])
        #expect(observation.costUSD == 0.0285)
    }

    @Test func envTextNeedsAHookThatRan() {
        #expect(Observation().text(for: .env("PITOT_CONF_1")) == "(no hook ran)")
        #expect(Observation().text(for: .hook(Self.localStart)) == Outcome.didNotRun)
        #expect(Observation().text(for: .initField(.outputStyle)) == "(no init message)")
    }

    @Test func envTextIsWhatEveryHookSaw() {
        var observation = Observation()
        observation.environments = [Self.projectStart: ["PITOT_CONF_1": "local"], Self.localStart: ["PITOT_CONF_1": "local"]]
        #expect(observation.text(for: .env("PITOT_CONF_1")) == "local")
        #expect(observation.text(for: .env("PITOT_CONF_2")) == Outcome.unset)
        #expect(observation.text(for: .hook(Self.localStart)) == Outcome.ran)
    }

    @Test func hooksThatDisagreeFail() {
        var observation = Observation()
        observation.environments = [Self.projectStart: ["PITOT_CONF_1": "project"], Self.localStart: [:]]
        #expect(observation.text(for: .env("PITOT_CONF_1")) == "(hooks disagree: (unset) | project)")
    }

    @Test func caseFailsWhenOneCheckDiffers() throws {
        let batch = try #require(Catalog.batches.first { $0.name == "empty-env" })
        let conformanceCase = try #require(batch.cases.first)
        let expectation = Expectation(plan: BatchPlan(batch: batch, workDirectory: URL(fileURLWithPath: "/tmp/conformance-test")))
        var observation = Observation()
        observation.environments = [Self.projectStart: ["PITOT_CONF_5": "project"], Self.localStart: ["PITOT_CONF_5": "project"]]
        #expect(CaseResult(conformanceCase, expectation: expectation, observation: observation, mutate: false).passed)

        observation.environments[Self.localStart] = nil
        observation.environments[Self.projectStart] = ["PITOT_CONF_5": "project"]
        let result = CaseResult(conformanceCase, expectation: expectation, observation: observation, mutate: false)
        #expect(!result.passed)
        #expect(result.checks.filter { !$0.passed }.map(\.check) == [.hook(Self.localStart)])
        #expect(Report.table([result]).contains("0 of 1 cases pass. Failing: env-empty-object"))
    }

    @Test func folderNameFollowsClaudeCode() {
        #expect(ProjectFolders.name(forProject: "/private/tmp/a_b.c/Run 1") == "-private-tmp-a-b-c-Run-1")
        #expect(ProjectFolders.name(forProject: "/tmp/é😀") == "-tmp----")
        #expect(ProjectFolders.name(forProject: "/" + String(repeating: "a", count: 200)) == nil)
    }

    @Test func removesOnlyNewFoldersThatHoldNoFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conformance-folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("config")
        let folders = ProjectFolders(environment: ["CLAUDE_CONFIG_DIR": configDirectory.path])
        let empty = URL(fileURLWithPath: "/tmp/conformance/empty")
        let withFile = URL(fileURLWithPath: "/tmp/conformance/with-file")
        let older = URL(fileURLWithPath: "/tmp/conformance/older")
        for project in [empty, withFile, older] {
            let name = try #require(ProjectFolders.name(forProject: project.path))
            try FileManager.default.createDirectory(
                at: folders.root.appendingPathComponent(name).appendingPathComponent("memory"),
                withIntermediateDirectories: true
            )
        }
        let withFileName = try #require(ProjectFolders.name(forProject: withFile.path))
        try Data("x".utf8).write(to: folders.root.appendingPathComponent(withFileName).appendingPathComponent("memory/note.md"))
        let olderName = try #require(ProjectFolders.name(forProject: older.path))
        let emptyName = try #require(ProjectFolders.name(forProject: empty.path))

        let cleanup = folders.removeEmpty(projects: [empty, withFile, older], before: [olderName])

        #expect(cleanup.removed == [emptyName])
        #expect(cleanup.kept == [withFileName])
        #expect(folders.names() == [withFileName, olderName])
    }
}
