import PitotCore
import Foundation
import Testing

@testable import Pitot

struct ErrorTextAndDiffTests {
    @Test func failedOperationIsNamedByItsKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PitotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("settings.json")
        try "{\n  \"env\": 5\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let file = SettingsFile(url: url, backupRoot: folder.appendingPathComponent("Backups", isDirectory: true))
        let operations: [JSONEdit.Operation] = [
            .set(path: ["model"], value: .json("opus")),
            .set(path: ["env", "DISABLE_TELEMETRY"], value: .json("1")),
        ]

        let result = Result { () throws(SettingsFileError) in try file.apply(operations: operations, expectedHash: try file.load().hash) }
        guard case .failure(let error) = result else {
            Issue.record("Expected the write to fail")
            return
        }
        #expect(
            ErrorText.describe(error, operations: operations)
                == "The change to env.DISABLE_TELEMETRY does not fit the file: env is not an object. Nothing was written.")
        #expect(ErrorText.describe(error).hasPrefix("Change 2 does not fit"))
    }

    @Test func restoreSkippedNamesTheBackup() {
        let text = ErrorText.describe(.restoreSkippedAnotherWriter(backup: "/tmp/backup.json"))
        #expect(text.contains("another program changed it"))
        #expect(text.contains("/tmp/backup.json"))
    }

    @Test func catalogFailuresAreReadable() async throws {
        let issue = LintIssue(rule: .duplicateId, tweakId: "tui", detail: "id \"tui\" is used by more than one row")
        #expect(ErrorText.describe(.lintFailed([issue])) == "The tweak catalog failed 1 check:\n- tui: id \"tui\" is used by more than one row")

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("PitotEmptyBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: empty))
        #expect(CatalogResource.load(bundle: bundle) == .failure(.missing("tweaks.json")))
    }

    @Test func lineDiffShowsOnlyChangedRegion() {
        let old = Array("a\nb\nc\nd\ne\nf\ng\nh\n".utf8)
        let new = Array("a\nb\nc\nd\nE\nf\ng\nh\n".utf8)
        let lines = LineDiff.unified(old: old, new: new)
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["e"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["E"])
        #expect(!lines.contains { $0.text == "a" })
    }
}
