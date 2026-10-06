import Foundation
import Testing

@testable import PitotCore

@Suite("Layers: managed settings reader")
struct LayersManagedTests {
    let folder: TemporaryDirectory

    init() throws {
        folder = try TemporaryDirectory()
    }

    private var reader: ManagedSettingsReader {
        ManagedSettingsReader(folder: folder.url)
    }

    private func dropIn(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: folder.file("managed-settings.d"), withIntermediateDirectories: true)
        try folder.write("managed-settings.d/\(name)", text)
    }

    private func value(_ path: [String]) throws -> JSONValue? {
        try #require(reader.load().document).value(at: path)
    }

    @Test func defaultFolderIsTheMacOSSystemFolder() {
        #expect(ManagedSettingsReader.defaultFolder.path == "/Library/Application Support/ClaudeCode")
    }

    @Test func missingFolderGivesMissingLayer() {
        let managed = ManagedSettingsReader(folder: folder.file("absent")).read()

        #expect(managed.layer.state == .missing)
        #expect(managed.layer.id == .managed)
        #expect(managed.files.isEmpty)
    }

    @Test func emptyFolderGivesMissingLayer() throws {
        try FileManager.default.createDirectory(at: folder.file("managed-settings.d"), withIntermediateDirectories: true)
        #expect(reader.load().state == .missing)
    }

    @Test func mainFileAloneKeepsItsBytes() throws {
        let url = try folder.write("managed-settings.json", "{\n  \"model\": \"opus\"\n}\n")
        let managed = reader.read()

        #expect(managed.layer.document?.bytes == (try readBytes(url)))
        #expect(managed.layer.url == folder.url)
        #expect(managed.files.map(\.url) == [url])
    }

    @Test func dropInsMergeAfterTheMainFileInAlphabeticalOrder() throws {
        try folder.write("managed-settings.json", #"{"model": "main", "cleanupPeriodDays": 1, "outputStyle": "main"}"#)
        try dropIn("20-security.json", #"{"model": "twenty"}"#)
        try dropIn("10-telemetry.json", #"{"model": "ten", "cleanupPeriodDays": 7}"#)

        #expect(try value(["model"]) == "twenty")
        #expect(try value(["cleanupPeriodDays"]) == 7)
        #expect(try value(["outputStyle"]) == "main")
        #expect(reader.read().files.map { $0.url?.lastPathComponent } == ["managed-settings.json", "10-telemetry.json", "20-security.json"])
    }

    /// Names sort by UTF-16 code unit (inferred).
    @Test func orderComparesCodeUnitsSoUppercaseSortsFirst() throws {
        try dropIn("a.json", #"{"model": "lowercase"}"#)
        try dropIn("B.json", #"{"model": "uppercase"}"#)

        #expect(try value(["model"]) == "lowercase")
    }

    @Test func listsJoinWithoutDuplicates() throws {
        try folder.write("managed-settings.json", #"{"permissions": {"deny": ["Bash(rm:*)", "WebFetch"]}}"#)
        try dropIn("10.json", #"{"permissions": {"deny": ["WebFetch", "Read(.env)"]}}"#)

        #expect(try value(["permissions", "deny"]) == ["Bash(rm:*)", "WebFetch", "Read(.env)"])
    }

    @Test func nestedBlocksMergeKeyByKey() throws {
        try folder.write("managed-settings.json", #"{"env": {"A": "1", "B": "1"}, "sandbox": {"enabled": true}}"#)
        try dropIn("10.json", #"{"env": {"B": "2", "C": "2"}, "sandbox": {"network": {"allowedDomains": ["x.com"]}}}"#)

        #expect(try value(["env"]) == ["A": "1", "B": "2", "C": "2"])
        #expect(try value(["sandbox", "enabled"]) == true)
        #expect(try value(["sandbox", "network", "allowedDomains"]) == ["x.com"])
    }

    @Test func wholeValueKeysReplaceTheEarlierFile() throws {
        try folder.write(
            "managed-settings.json",
            #"{"fallbackModel": ["a", "b"], "modelPicker": {"options": [{"model": "a"}], "replaceBuiltInOptions": true}, "extraKnownMarketplaces": {"team": {"source": "one", "autoUpdate": true}, "other": {"source": "o"}}}"#
        )
        try dropIn(
            "10.json",
            #"{"fallbackModel": ["c"], "modelPicker": {"options": [{"model": "c"}]}, "extraKnownMarketplaces": {"team": {"source": "two"}}}"#
        )

        #expect(try value(["fallbackModel"]) == ["c"])
        #expect(try value(["modelPicker"]) == ["options": [["model": "c"]]])
        #expect(try value(["extraKnownMarketplaces", "team"]) == ["source": "two"])
        #expect(try value(["extraKnownMarketplaces", "other"]) == ["source": "o"])
    }

    @Test func ignoresHiddenFilesOtherExtensionsAndFolders() throws {
        try dropIn("10.json", #"{"model": "kept"}"#)
        try dropIn(".20-hidden.json", #"{"model": "hidden"}"#)
        try dropIn("30-notes.txt", #"{"model": "text"}"#)
        try dropIn("40-upper.JSON", #"{"model": "upper"}"#)
        try FileManager.default.createDirectory(at: folder.file("managed-settings.d/50-folder.json"), withIntermediateDirectories: false)

        #expect(try value(["model"]) == "kept")
        #expect(reader.read().files.count == 1)
    }

    @Test func symlinkedDropInIsRead() throws {
        let target = try folder.write("elsewhere.json", #"{"model": "linked"}"#)
        try dropIn("10.json", #"{"model": "plain"}"#)
        try FileManager.default.createSymbolicLink(at: folder.file("managed-settings.d/20-link.json"), withDestinationURL: target)

        #expect(try value(["model"]) == "linked")
    }

    @Test func dropInsWorkWithoutTheMainFile() throws {
        try dropIn("10.json", #"{"model": "drop-in"}"#)
        #expect(try value(["model"]) == "drop-in")
    }

    @Test func emptyManagedFileCountsAsEmptyObject() throws {
        try folder.write("managed-settings.json", "")
        try dropIn("10.json", "  ")

        let document = try #require(reader.load().document)
        #expect(document.decode(document.root) == .object([]))
    }

    @Test func invalidDropInMakesTheLayerInvalid() throws {
        try folder.write("managed-settings.json", #"{"model": "opus"}"#)
        try dropIn("20-bad.json", #"{"model": "#)
        let layer = reader.load()

        guard case .invalid(.managedFile(let name, .syntax)) = layer.state else {
            Issue.record("expected an invalid drop-in, got \(layer.state)")
            return
        }
        #expect(name == "managed-settings.d/20-bad.json")
    }

    @Test func nonObjectMainFileMakesTheLayerInvalid() throws {
        try folder.write("managed-settings.json", "[]")
        #expect(LayersFixtures.problem(of: reader.load()) == .managedFile(name: "managed-settings.json", problem: .notAnObject))
    }

    /// Inferred: each file is checked before the merge, so a null drops only that file's key.
    @Test func nullInADropInRemovesOnlyThatFilesKey() throws {
        try folder.write("managed-settings.json", #"{"model": "opus"}"#)
        try dropIn("10.json", #"{"model": null, "outputStyle": "x"}"#)

        #expect(try value(["model"]) == "opus")
        #expect(try value(["outputStyle"]) == "x")
    }

    @Test(.enabled(if: getuid() != 0, "root can read a file with mode 000"))
    func unreadableDropInMakesTheLayerUnreadable() throws {
        try folder.write("managed-settings.json", #"{"model": "opus"}"#)
        try dropIn("10.json", "{}")
        chmod(folder.file("managed-settings.d/10.json").path, 0)

        #expect(LayersFixtures.isUnreadable(reader.load()))
    }

    @Test(.enabled(if: getuid() != 0, "root can list a folder with mode 000"))
    func unreadableDropInFolderMakesTheLayerUnreadable() throws {
        try folder.write("managed-settings.json", #"{"model": "opus"}"#)
        try dropIn("10.json", "{}")
        chmod(folder.file("managed-settings.d").path, 0)

        #expect(LayersFixtures.isUnreadable(reader.load()))
    }

    @Test func readingNeverChangesTheFolder() throws {
        try folder.write("managed-settings.json", #"{"model": null, "env": {"A": null}}"#)
        try dropIn("10.json", #"{"model": "opus"}"#)
        let paths = ["managed-settings.json", "managed-settings.d/10.json"]
        let before = try paths.map { try readBytes(folder.file($0)) }
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()

        _ = reader.read()

        #expect(try paths.map { try readBytes(folder.file($0)) } == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == listing)
    }
}
