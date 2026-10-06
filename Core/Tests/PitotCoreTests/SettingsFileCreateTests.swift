import Foundation
import Testing
import os

@testable import PitotCore

@Suite("Create if missing")
struct SettingsFileCreateTests {
    let directory: TemporaryDirectory
    let root: URL

    init() throws {
        directory = try TemporaryDirectory()
        root = directory.file("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    private func creatingFile(_ relativePath: String, initialContent: [UInt8]? = nil) -> SettingsFile {
        SettingsFile(
            url: root.appendingPathComponent(relativePath),
            backupRoot: directory.file("Backups"),
            missingFilePolicy: .create(root: root, initialContent: initialContent)
        )
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func leftoverTemporaryFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") && $0.contains(".pitot-") }
    }

    private let model = JSONEdit.Operation.set(path: ["model"], value: .json("opus"))

    @Test func missingFileIsStillAnErrorByDefault() {
        let url = root.appendingPathComponent(".claude/settings.local.json")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))

        #expect(throws: SettingsFileError.missingFile(path: url.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(!exists(root.appendingPathComponent(".claude")))
    }

    @Test func createsTheFileAndNestedFoldersInOneWriteWithoutABackup() throws {
        let file = creatingFile("a/b/.claude/settings.local.json")

        let result = try file.apply(
            operations: [model, .set(path: ["env", "A"], value: .json("1"))],
            expectedHash: SettingsFile.missingFileHash
        )

        let written = try readBytes(file.url)
        #expect(written.text == "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n")
        #expect(result.createdFile)
        #expect(result.backup == nil)
        #expect(result.rebased == false)
        #expect(result.snapshot.bytes == written)
        #expect(result.changes.map(\.path) == [["model"], ["env"]])
        #expect(result.createdDirectories.map { $0.path.replacingOccurrences(of: root.path, with: "") } == ["/a", "/a/b", "/a/b/.claude"])
        #expect(try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int == 0o644)
        #expect(!exists(directory.file("Backups")))
        #expect(try leftoverTemporaryFiles(in: root.appendingPathComponent("a/b/.claude")).isEmpty)
    }

    @Test func createsInAnExistingFolderAndMakesNoFolder() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: false)
        let file = creatingFile(".claude/settings.local.json")

        let result = try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)

        #expect(result.createdFile)
        #expect(result.createdDirectories.isEmpty)
        #expect(try readBytes(file.url).text == "{\n  \"model\": \"opus\"\n}\n")
    }

    @Test func startsFromTheGivenInitialContent() throws {
        let initial = [UInt8]("{\n    \"bindings\": []\n}\n")
        let file = creatingFile(".claude/keybindings.json", initialContent: initial)
        let append = JSONEdit.Operation.appendElement(path: ["bindings"], value: .json(["context": "Chat"]))

        _ = try file.apply(operations: [append], expectedHash: SettingsFile.missingFileHash)

        #expect(try readBytes(file.url) == (try JSONEdit.apply(append, to: initial).bytes))
    }

    @Test func refusesInitialContentThatIsNotJSON() {
        let file = creatingFile("settings.json", initialContent: [UInt8]("nope"))

        #expect {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        } throws: { error in
            guard case SettingsFileError.invalidJSON = error else { return false }
            return true
        }
        #expect(!exists(file.url))
    }

    @Test func singleOperationCreatesTheFileToo() throws {
        let file = creatingFile(".claude/settings.local.json")

        let result = try file.apply(model, expectedHash: SettingsFile.missingFileHash)

        #expect(result.createdFile)
        #expect(result.backup == nil)
        #expect(try readBytes(file.url).text == "{\n  \"model\": \"opus\"\n}\n")
    }

    /// Decision: an empty list stays a no-op, so it never creates the file.
    @Test func emptyListDoesNotCreateTheFile() {
        let file = creatingFile(".claude/settings.local.json")

        #expect(throws: SettingsFileError.missingFile(path: file.url.path)) {
            try file.apply(operations: [], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(!exists(root.appendingPathComponent(".claude")))
    }

    @Test func failingOperationCreatesNeitherFileNorFolder() {
        let file = creatingFile("a/.claude/settings.local.json")

        #expect(throws: SettingsFileError.edit(.init(index: 1, reason: .keyNotFound(path: ["missing"])))) {
            try file.apply(operations: [model, .remove(path: ["missing"])], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(!exists(root.appendingPathComponent("a")))
    }

    // MARK: Unsafe locations

    @Test func refusesAFolderThatIsASymlinkOutOfTheRoot() throws {
        let outside = directory.file("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = root.appendingPathComponent(".claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = creatingFile(".claude/settings.local.json")

        #expect(throws: SettingsFileError.outsideRoot(path: link.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func refusesASymlinkOutOfTheRootHigherUpThePath() throws {
        let outside = directory.file("outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = creatingFile("sub/.claude/settings.local.json")

        #expect(throws: SettingsFileError.outsideRoot(path: link.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.appendingPathComponent(".claude").path).isEmpty)
    }

    @Test func acceptsASymlinkedFolderThatStaysInsideTheRoot() throws {
        let real = root.appendingPathComponent("shared-claude")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".claude"), withDestinationURL: real)
        let file = creatingFile(".claude/settings.local.json")

        let result = try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)

        #expect(result.createdFile)
        #expect(try readBytes(real.appendingPathComponent("settings.local.json")).text == "{\n  \"model\": \"opus\"\n}\n")
    }

    @Test func refusesAParentThatIsARegularFile() throws {
        let blocker = root.appendingPathComponent(".claude")
        try Data("not a folder".utf8).write(to: blocker)
        let file = creatingFile(".claude/settings.local.json")

        #expect(throws: SettingsFileError.io(operation: .createDirectory, path: blocker.path, errno: ENOTDIR)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(try readBytes(blocker).text == "not a folder")
    }

    @Test func refusesAFileOutsideTheRoot() {
        let url = directory.file("elsewhere/settings.json")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"), missingFilePolicy: .create(root: root))

        #expect(throws: SettingsFileError.outsideRoot(path: url.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(!exists(directory.file("elsewhere")))
    }

    @Test func refusesADanglingSymlinkInPlaceOfTheFile() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: false)
        let link = root.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.file("nowhere.json"))
        let file = creatingFile(".claude/settings.local.json")

        #expect(throws: SettingsFileError.notARegularFile(path: link.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(!exists(directory.file("nowhere.json")))
    }

    // MARK: Races

    @Test func fileThatAppearsBeforeTheRenameIsTreatedAsExistingAndRebased() throws {
        var file = creatingFile(".claude/settings.local.json")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        file.hooks.beforeCommit = { target in
            let isFirst = calls.withLock { count in
                count += 1
                return count == 1
            }
            if isFirst {
                FileManager.default.createFile(atPath: target.path, contents: Data("{\n  \"theme\": \"dark\"\n}\n".utf8))
            }
        }

        let result = try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)

        #expect(result.rebased)
        #expect(result.createdFile == false)
        #expect(try readBytes(file.url).text == "{\n  \"theme\": \"dark\",\n  \"model\": \"opus\"\n}\n")
        #expect(try readBytes(try #require(result.backup)).text == "{\n  \"theme\": \"dark\"\n}\n")
        #expect(try leftoverTemporaryFiles(in: root.appendingPathComponent(".claude")).isEmpty)
    }

    @Test func fileDeletedSinceLoadIsCreatedAgainAndMarkedRebased() throws {
        let file = creatingFile("settings.json")
        try Data("{\n  \"model\": \"haiku\"\n}\n".utf8).write(to: file.url)
        let snapshot = try file.load()
        try FileManager.default.removeItem(at: file.url)

        let result = try file.apply(operations: [model], expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(result.createdFile)
        #expect(try readBytes(file.url).text == "{\n  \"model\": \"opus\"\n}\n")
    }

    // MARK: Verification after create

    @Test func createdFileThatDoesNotParseIsRemovedWithItsFolders() throws {
        var file = creatingFile("a/.claude/settings.local.json")
        file.hooks.beforeWrite = { _ in [UInt8]("{\"broken\": ") }

        #expect(throws: SettingsFileError.createdFileInvalid(path: file.url.path, removed: true, reason: .unexpectedEnd)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }

        #expect(!exists(root.appendingPathComponent("a")))
    }

    @Test func createdFileReplacedByAnotherWriterIsLeftAlone() throws {
        var file = creatingFile(".claude/settings.local.json")
        let other = "{\"broken\": "
        file.hooks.afterCommit = { target in
            FileManager.default.createFile(atPath: target.path, contents: Data(other.utf8))
        }

        #expect(throws: SettingsFileError.createdFileInvalid(path: file.url.path, removed: false, reason: .unexpectedEnd)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }

        #expect(try readBytes(file.url).text == other)
    }
}
