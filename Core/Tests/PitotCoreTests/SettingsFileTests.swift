import Foundation
import Testing
import os

@testable import PitotCore

@Suite("Safe write")
struct SettingsFileTests {
    let directory: TemporaryDirectory
    let backups: URL

    init() throws {
        directory = try TemporaryDirectory()
        backups = directory.file("Backups")
    }

    private func settingsFile(at url: URL, limit: Int = 20, emptyFilePolicy: SettingsFile.EmptyFilePolicy = .reject) -> SettingsFile {
        SettingsFile(url: url, backupRoot: backups, backupLimit: limit, emptyFilePolicy: emptyFilePolicy)
    }

    /// Keybinding files unbind a key with `null`, so they allow it.
    private func keybindingsFile(at url: URL) -> SettingsFile {
        SettingsFile(url: url, backupRoot: backups, nullValuePolicy: .allow)
    }

    private func copyFixture(_ name: String, as fileName: String = "settings.json") throws -> URL {
        let url = directory.file(fileName)
        try Data(try Fixtures.bytes(name)).write(to: url)
        return url
    }

    /// The backups of `url`, by default `settings.json` in the test folder, oldest first.
    private func backupFiles(of url: URL? = nil) throws -> [URL] {
        let target = (url ?? directory.file("settings.json")).resolvingSymlinksInPath()
        let folder = backups.appendingPathComponent(SettingsFile.backupFolderName(for: target))
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func leftoverTemporaryFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
    }

    // MARK: Load

    @Test func loadReturnsBytesAndSHA256() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let snapshot = try settingsFile(at: url).load()
        #expect(snapshot.bytes == [UInt8]("{\"a\": 1}\n"))
        #expect(snapshot.hash == "e8c628edc9968ef0c668f54e0ba2636b35503357eb1aca0ddc828aeace432f67")
        #expect(snapshot.document.value(at: ["a"]) == 1)
        #expect(snapshot.url == url)
    }

    @Test func loadRejectsMissingFile() {
        let url = directory.file("missing.json")
        #expect(throws: SettingsFileError.missingFile(path: url.path)) {
            try settingsFile(at: url).load()
        }
    }

    @Test func loadRejectsInvalidJSON() throws {
        let url = try copyFixture("invalid-comment")
        #expect(throws: SettingsFileError.invalidJSON(.comment(offset: 4))) {
            try settingsFile(at: url).load()
        }
    }

    @Test func emptyFileIsRejectedByDefault() throws {
        let url = try directory.write("settings.json", "")
        let file = settingsFile(at: url)
        #expect(throws: SettingsFileError.emptyFile(path: url.path)) {
            try file.load()
        }
        #expect(throws: SettingsFileError.emptyFile(path: url.path)) {
            try file.apply(.set(path: ["a"], value: .json(1)), expectedHash: "")
        }
    }

    @Test func emptyFileIsAnEmptyObjectWhenCallerOptsIn() throws {
        let url = try directory.write("settings.json", "")
        let file = settingsFile(at: url, emptyFilePolicy: .treatAsEmptyObject)
        let snapshot = try file.load()
        #expect(snapshot.bytes.isEmpty)
        #expect(snapshot.document.value(at: []) == [:])
        let result = try file.apply(.set(path: ["a"], value: .json(1)), expectedHash: snapshot.hash)
        #expect(try readBytes(url).text == "{\n  \"a\": 1\n}\n")
        #expect(result.rebased == false)
    }

    // MARK: Apply

    @Test func applyChangesOnlyTheKeyAndBacksUpTheOldFile() throws {
        let url = try copyFixture("settings-synthetic")
        let original = try readBytes(url)
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        let result = try file.apply(.set(path: ["tui"], value: .json("fullscreen")), expectedHash: snapshot.hash)
        let written = try readBytes(url)
        #expect(written == (try Fixtures.bytes(atRepoPath: "Fixtures/expected/settings-synthetic.10.json")))
        #expect(result.rebased == false)
        #expect(result.snapshot.bytes == written)
        #expect(result.snapshot.hash != snapshot.hash)
        #expect(result.change.path == ["tui"])
        #expect(try readBytes(try #require(result.backup)) == original)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func backupsArePrivateAndLimited() throws {
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let file = settingsFile(at: url, limit: 3)
        for value in 1...5 {
            let snapshot = try file.load()
            _ = try file.apply(.set(path: ["n"], value: .json(.number(JSONNumber(value)))), expectedHash: snapshot.hash)
        }
        let files = try backupFiles()
        #expect(files.count == 3)
        #expect(try files.map { try readBytes($0).text } == ["{\"n\": 2}\n", "{\"n\": 3}\n", "{\"n\": 4}\n"])
        for backup in files {
            let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        let folderMode = try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }

    @Test func preservesPOSIXMode() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        chmod(url.path, 0o640)
        let file = settingsFile(at: url)
        _ = try file.apply(.set(path: ["a"], value: .json(2)), expectedHash: try file.load().hash)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test func writesThroughSymlinkToItsTarget() throws {
        let real = directory.file("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = try directory.write("real/settings.json", "{\"a\": 1}\n")
        let link = directory.file("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = settingsFile(at: link)
        let snapshot = try file.load()
        #expect(snapshot.url == target)
        _ = try file.apply(.set(path: ["a"], value: .json(2)), expectedHash: snapshot.hash)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try readBytes(target).text == "{\"a\": 2}\n")
        #expect(try leftoverTemporaryFiles(in: real).isEmpty)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func refusesReadOnlyFile() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        chmod(url.path, 0o444)
        #expect(throws: SettingsFileError.readOnly(path: url.path)) {
            try file.apply(.set(path: ["a"], value: .json(2)), expectedHash: snapshot.hash)
        }
        #expect(try readBytes(url).text == "{\"a\": 1}\n")
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func refusesMissingFile() {
        let url = directory.file("missing.json")
        #expect(throws: SettingsFileError.missingFile(path: url.path)) {
            try settingsFile(at: url).apply(.set(path: ["a"], value: .json(1)), expectedHash: "")
        }
    }

    @Test func reportsEditErrorWhenFileIsUnchanged() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let file = settingsFile(at: url)
        #expect(throws: SettingsFileError.edit(.init(index: 0, reason: .keyNotFound(path: ["b"])))) {
            try file.apply(.remove(path: ["b"]), expectedHash: try file.load().hash)
        }
    }

    // MARK: Apply a list

    @Test func applyListWritesEveryKeyWithOneBackup() throws {
        let url = try copyFixture("crlf")
        let original = try readBytes(url)
        let file = settingsFile(at: url)
        let operations: [JSONEdit.Operation] = [
            .set(path: ["tui"], value: .json("fullscreen")),
            .set(path: ["env", "B"], value: .json("2")),
            .remove(path: ["verbose"]),
        ]

        let result = try file.apply(operations: operations, expectedHash: try file.load().hash)

        let written = try readBytes(url)
        #expect(
            written.text
                == "{\r\n  \"theme\": \"dark\",\r\n  \"env\": {\r\n    \"A\": \"1\",\r\n    \"B\": \"2\"\r\n  },\r\n  \"tui\": \"fullscreen\"\r\n}\r\n")
        #expect(result.changes.map(\.path) == [["tui"], ["env", "B"], ["verbose"]])
        #expect(result.rebased == false)
        #expect(result.snapshot.bytes == written)
        #expect(try backupFiles().count == 1)
        #expect(try readBytes(try #require(result.backup)) == original)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func failingOperationLeavesFileUnchangedAndNamesItsIndex() throws {
        let url = try copyFixture("crlf")
        let original = try readBytes(url)
        let file = settingsFile(at: url)
        let operations: [JSONEdit.Operation] = [
            .set(path: ["tui"], value: .json("fullscreen")),
            .remove(path: ["missing"]),
            .set(path: ["env", "B"], value: .json("2")),
        ]

        #expect(throws: SettingsFileError.edit(.init(index: 1, reason: .keyNotFound(path: ["missing"])))) {
            try file.apply(operations: operations, expectedHash: try file.load().hash)
        }

        #expect(try readBytes(url) == original)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    /// Decision: an empty list is a no-op. It reads the file but needs no write
    /// permission, writes nothing and makes no backup.
    @Test func emptyListWritesNothingAndMakesNoBackup() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        chmod(url.path, 0o444)

        let result = try file.apply(operations: [], expectedHash: snapshot.hash)

        #expect(result.changes.isEmpty)
        #expect(result.backup == nil)
        #expect(result.rebased == false)
        #expect(result.snapshot == snapshot)
        #expect(try readBytes(url).text == "{\"a\": 1}\n")
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func emptyListReportsAFileChangedSinceLoad() throws {
        let url = try directory.write("settings.json", "{\"a\": 1}\n")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        try Data("{\"a\": 2}\n".utf8).write(to: url)

        let result = try file.apply(operations: [], expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(result.snapshot.bytes == [UInt8]("{\"a\": 2}\n"))
        #expect(result.backup == nil)
    }

    @Test func listBackupsStayWithinTheLimit() throws {
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let file = settingsFile(at: url, limit: 2)
        var replaced: [[UInt8]] = []
        for value in 1...4 {
            replaced.append(try readBytes(url))
            let number = JSONValue.number(JSONNumber(value))
            _ = try file.apply(
                operations: [.set(path: ["n"], value: .json(number)), .set(path: ["m"], value: .json(number))],
                expectedHash: try file.load().hash
            )
        }
        let files = try backupFiles()
        #expect(files.count == 2)
        #expect(try files.map(readBytes) == Array(replaced.suffix(2)))
    }

    // MARK: Concurrent writers

    @Test func reappliesOperationWhenFileChangedSinceLoad() throws {
        let url = try copyFixture("crlf")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        let external = try JSONEdit.set(["theme"], to: .json("solarized"), in: try readBytes(url)).bytes
        try Data(external).write(to: url)

        let result = try file.apply(.set(path: ["tui"], value: .json("fullscreen")), expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(
            try readBytes(url).text
                == "{\r\n  \"theme\": \"solarized\",\r\n  \"verbose\": true,\r\n  \"env\": {\r\n    \"A\": \"1\"\r\n  },\r\n  \"tui\": \"fullscreen\"\r\n}\r\n")
        #expect(try readBytes(try #require(result.backup)) == external)
    }

    @Test func retriesWhenAnotherWriterLandsBetweenReadAndRename() throws {
        let url = try directory.write("settings.json", "{\n  \"theme\": \"dark\"\n}\n")
        let writes = OSAllocatedUnfairLock(initialState: 0)
        var file = settingsFile(at: url)
        file.hooks.beforeCommit = { target in
            let isFirst = writes.withLock { count in
                count += 1
                return count == 1
            }
            if isFirst {
                FileManager.default.createFile(atPath: target.path, contents: Data("{\n  \"theme\": \"light\"\n}\n".utf8))
            }
        }
        let snapshot = try file.load()

        let result = try file.apply(.set(path: ["tui"], value: .json("fullscreen")), expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(writes.withLock { $0 } == 2)
        #expect(try readBytes(url).text == "{\n  \"theme\": \"light\",\n  \"tui\": \"fullscreen\"\n}\n")
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func givesUpWhenTheFileKeepsChanging() throws {
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var file = settingsFile(at: url)
        file.hooks.beforeCommit = { target in
            let next = counter.withLock { count in
                count += 1
                return count
            }
            FileManager.default.createFile(atPath: target.path, contents: Data("{\"n\": \(next)}\n".utf8))
        }
        let snapshot = try file.load()
        #expect(throws: SettingsFileError.changedDuringWrite(path: url.path)) {
            try file.apply(.set(path: ["tui"], value: .json("fullscreen")), expectedHash: snapshot.hash)
        }
        #expect(try readBytes(url).text == "{\"n\": \(SettingsFile.maximumAttempts)}\n")
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func reportsConflictWhenOperationCannotBeReapplied() throws {
        let url = try directory.write("settings.json", "{\"env\": {\"A\": \"1\"}}\n")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        try Data("{\"env\": \"flat\"}\n".utf8).write(to: url)
        #expect(throws: SettingsFileError.conflict(.init(index: 0, reason: .notAnObject(path: ["env"])))) {
            try file.apply(.set(path: ["env", "B"], value: .json("2")), expectedHash: snapshot.hash)
        }
        #expect(try readBytes(url).text == "{\"env\": \"flat\"}\n")
    }

    @Test func reappliesTheWholeListWhenFileChangedSinceLoad() throws {
        let url = try copyFixture("crlf")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        let external = try JSONEdit.set(["theme"], to: .json("solarized"), in: try readBytes(url)).bytes
        try Data(external).write(to: url)
        let operations: [JSONEdit.Operation] = [
            .set(path: ["tui"], value: .json("fullscreen")),
            .set(path: ["env", "B"], value: .json("2")),
        ]

        let result = try file.apply(operations: operations, expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(
            try readBytes(url).text
                == "{\r\n  \"theme\": \"solarized\",\r\n  \"verbose\": true,\r\n  \"env\": {\r\n    \"A\": \"1\",\r\n    \"B\": \"2\"\r\n  },\r\n"
                + "  \"tui\": \"fullscreen\"\r\n}\r\n")
        #expect(try backupFiles().count == 1)
        #expect(try readBytes(try #require(result.backup)) == external)
    }

    @Test func reportsConflictAtTheIndexOfTheOperationThatNoLongerFits() throws {
        let url = try directory.write("settings.json", "{\"a\": 1, \"env\": {\"A\": \"1\"}}\n")
        let file = settingsFile(at: url)
        let snapshot = try file.load()
        try Data("{\"a\": 1, \"env\": \"flat\"}\n".utf8).write(to: url)
        let operations: [JSONEdit.Operation] = [
            .set(path: ["a"], value: .json(2)),
            .set(path: ["env", "B"], value: .json("2")),
        ]

        #expect(throws: SettingsFileError.conflict(.init(index: 1, reason: .notAnObject(path: ["env"])))) {
            try file.apply(operations: operations, expectedHash: snapshot.hash)
        }

        #expect(try readBytes(url).text == "{\"a\": 1, \"env\": \"flat\"}\n")
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    // MARK: Arrays

    @Test func appliesElementOperationsAsOneWrite() throws {
        let url = try copyFixture("keybindings")
        let file = keybindingsFile(at: url)
        let operations: [JSONEdit.Operation] = [
            .appendElement(path: ["bindings"], value: .json(["context": "Help", "bindings": [:]])),
            .removeElement(path: ["bindings"], index: 0),
            .editElement(path: ["bindings"], index: 0, inner: .set(path: ["context"], value: .json("Autocomplete"))),
        ]

        let result = try file.apply(operations: operations, expectedHash: try file.load().hash)

        var expected = try Fixtures.bytes("keybindings")
        for operation in operations {
            expected = try JSONEdit.apply(operation, to: expected).bytes
        }
        #expect(try readBytes(url) == expected)
        #expect(result.changes.map(\.path) == [["bindings"], ["bindings"], ["bindings"]])
        #expect(result.rebased == false)
        #expect(try backupFiles().count == 1)
    }

    /// Decision: an index read from older content can name another element now, so an operation
    /// that picks an element by index is not re-applied to content that changed since it was loaded.
    @Test func refusesAnElementIndexWhenTheFileChangedSinceLoad() throws {
        let url = try copyFixture("keybindings")
        let file = keybindingsFile(at: url)
        let snapshot = try file.load()
        let insert = JSONEdit.Operation.insertElement(path: ["bindings"], index: 0, value: .json(["context": "Help", "bindings": [:]]))
        let external = try JSONEdit.apply(insert, to: try readBytes(url)).bytes
        try Data(external).write(to: url)
        let append = JSONEdit.Operation.appendElement(path: ["bindings"], value: .json(["context": "Chat", "bindings": [:]]))

        #expect(throws: SettingsFileError.conflict(.init(index: 1, reason: .staleElementIndex(path: ["bindings"], index: 0)))) {
            try file.apply(operations: [append, .removeElement(path: ["bindings"], index: 0)], expectedHash: snapshot.hash)
        }
        let edit = JSONEdit.Operation.editElement(path: ["bindings"], index: 1, inner: .remove(path: ["bindings", "ctrl+e"]))
        #expect(throws: SettingsFileError.conflict(.init(index: 0, reason: .staleElementIndex(path: ["bindings"], index: 1)))) {
            try file.apply(edit, expectedHash: snapshot.hash)
        }
        #expect(try readBytes(url) == external)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func reappliesAnAppendWhenTheFileChangedSinceLoad() throws {
        let url = try copyFixture("keybindings")
        let file = keybindingsFile(at: url)
        let snapshot = try file.load()
        let insert = JSONEdit.Operation.insertElement(path: ["bindings"], index: 0, value: .json(["context": "Help", "bindings": [:]]))
        let external = try JSONEdit.apply(insert, to: try readBytes(url)).bytes
        try Data(external).write(to: url)
        let append = JSONEdit.Operation.appendElement(path: ["bindings"], value: .json(["context": "Chat", "bindings": [:]]))

        let result = try file.apply(append, expectedHash: snapshot.hash)

        #expect(result.rebased)
        #expect(try readBytes(url) == (try JSONEdit.apply(append, to: external).bytes))
    }

    // MARK: Size limit

    @Test func refusesAFileOverEightMebibytesBeforeReadingIt() throws {
        let url = directory.file("settings.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 9 * 1024 * 1024)
        try handle.close()
        let file = settingsFile(at: url)
        let tooLarge = SettingsFileError.io(operation: .read, path: url.path, errno: EFBIG)

        #expect(throws: tooLarge) { try file.load() }
        #expect(throws: tooLarge) {
            try file.apply(operations: [.set(path: ["a"], value: .json(1))], expectedHash: "")
        }

        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    @Test func readsAFileOfExactlyEightMebibytes() throws {
        let limit = POSIXFile.maximumFileSize
        let url = try directory.write("settings.json", "{}" + String(repeating: " ", count: limit - 3) + "\n")

        #expect(try settingsFile(at: url).load().bytes.count == limit)
    }

    // MARK: Backup folders

    @Test func filesWithTheSameNameKeepSeparateBackupPools() throws {
        let first = directory.file("one/settings.json")
        let second = directory.file("two/settings.json")
        for (number, url) in [first, second].enumerated() {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
            try Data("{\"file\": \(number), \"n\": 0}\n".utf8).write(to: url)
            let file = settingsFile(at: url, limit: 2)
            for value in 1...3 {
                _ = try file.apply(.set(path: ["n"], value: .json(.number(JSONNumber(value)))), expectedHash: try file.load().hash)
            }
        }

        let folders = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(folders.count == 2)
        #expect(folders.allSatisfy { $0.hasPrefix("settings-") })
        #expect(try backupFiles(of: first).map { try readBytes($0).text } == ["{\"file\": 0, \"n\": 1}\n", "{\"file\": 0, \"n\": 2}\n"])
        #expect(try backupFiles(of: second).map { try readBytes($0).text } == ["{\"file\": 1, \"n\": 1}\n", "{\"file\": 1, \"n\": 2}\n"])
    }

    @Test func backupFolderIsTheBaseNameAndAShortHashOfThePath() {
        let path = "/Users/someone/.claude/settings.json"

        let name = SettingsFile.backupFolderName(for: URL(fileURLWithPath: path))

        #expect(name == "settings-" + SettingsFile.sha256([UInt8](path)).prefix(8))
    }

    @Test func olderBackupFoldersWithoutAHashAreLeftAlone() throws {
        try FileManager.default.createDirectory(at: backups.appendingPathComponent("settings"), withIntermediateDirectories: true)
        let old = try directory.write("Backups/settings/20250101T000000.000000Z.json", "{}\n")
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let file = settingsFile(at: url, limit: 1)

        for value in 1...2 {
            _ = try file.apply(.set(path: ["n"], value: .json(.number(JSONNumber(value)))), expectedHash: try file.load().hash)
        }

        #expect(try readBytes(old).text == "{}\n")
        #expect(try backupFiles().count == 1)
    }

    @Test func anOldBackupThatCannotBeRemovedDoesNotStopTheWrite() throws {
        let url = try directory.write("settings.json", "{\"n\": 0}\n")
        let file = settingsFile(at: url, limit: 1)
        _ = try file.apply(.set(path: ["n"], value: .json(1)), expectedHash: try file.load().hash)
        let folder = try #require(try backupFiles().first).deletingLastPathComponent()
        let stuck = folder.appendingPathComponent("00000000T000000.000000Z.json", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck.appendingPathComponent("inside"), withIntermediateDirectories: true)

        let result = try file.apply(.set(path: ["n"], value: .json(2)), expectedHash: try file.load().hash)

        #expect(try readBytes(url).text == "{\"n\": 2}\n")
        #expect(try readBytes(try #require(result.backup)).text == "{\"n\": 1}\n")
        #expect(FileManager.default.fileExists(atPath: stuck.path))
        #expect(try backupFiles().map(\.lastPathComponent) == [stuck.lastPathComponent, try #require(result.backup).lastPathComponent])
    }

    // MARK: Verification after write

    @Test func restoresBackupWhenPitotsOwnBytesDoNotParse() throws {
        let url = try copyFixture("tabs")
        let original = try readBytes(url)
        var file = settingsFile(at: url)
        file.hooks.beforeWrite = { _ in [UInt8]("{\"broken\": ") }
        let snapshot = try file.load()
        #expect {
            try file.apply(.set(path: ["verbose"], value: .json(false)), expectedHash: snapshot.hash)
        } throws: { error in
            guard case SettingsFileError.restoredFromBackup(_, reason: .unexpectedEnd) = error else { return false }
            return true
        }
        #expect(try readBytes(url) == original)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func leavesTheFileAloneWhenAnotherWriterReplacedItAfterPitot() throws {
        let url = try copyFixture("tabs")
        let original = try readBytes(url)
        let other = "{\"broken\": "
        var file = settingsFile(at: url)
        file.hooks.afterCommit = { target in
            FileManager.default.createFile(atPath: target.path, contents: Data(other.utf8))
        }
        let operations: [JSONEdit.Operation] = [
            .set(path: ["verbose"], value: .json(false)),
            .set(path: ["tui"], value: .json("fullscreen")),
        ]

        let error = try #require(throws: SettingsFileError.self) {
            try file.apply(operations: operations, expectedHash: try file.load().hash)
        }

        guard case .restoreSkippedAnotherWriter(let backup) = error else {
            Issue.record("expected restoreSkippedAnotherWriter, got \(error)")
            return
        }
        #expect(try readBytes(url).text == other)
        #expect(try readBytes(URL(fileURLWithPath: backup)) == original)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }

    @Test func skipsTheRestoreWhenAnotherWriterLandsWhileRestoring() throws {
        let url = try copyFixture("tabs")
        let other = "{\"other\": true}\n"
        var file = settingsFile(at: url)
        file.hooks.beforeWrite = { _ in [UInt8]("{\"broken\": ") }
        file.hooks.beforeRestore = { target in
            FileManager.default.createFile(atPath: target.path, contents: Data(other.utf8))
        }

        let error = try #require(throws: SettingsFileError.self) {
            try file.apply(operations: [.set(path: ["verbose"], value: .json(false))], expectedHash: try file.load().hash)
        }

        guard case .restoreSkippedAnotherWriter = error else {
            Issue.record("expected restoreSkippedAnotherWriter, got \(error)")
            return
        }
        #expect(try readBytes(url).text == other)
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
    }
}
