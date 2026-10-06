import Foundation
import Testing
import os

@testable import PitotCore

@Suite("Undo")
struct UndoLogTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// Keybinding fixtures unbind keys with `null`, so their file allows it.
    private func settingsFile(_ fixture: String) throws -> SettingsFile {
        let url = directory.file("settings.json")
        try Data(try Fixtures.bytes(fixture)).write(to: url)
        let nullValuePolicy: SettingsFile.NullValuePolicy = fixture.hasPrefix("keybindings") ? .allow : .reject
        return SettingsFile(url: url, backupRoot: directory.file("Backups"), nullValuePolicy: nullValuePolicy)
    }

    private func pitotApply(_ operation: JSONEdit.Operation, to file: SettingsFile, log: inout UndoLog) throws {
        let result = try file.apply(operation, expectedHash: try file.load().hash)
        log.record(result.change)
    }

    private func pitotApply(_ operations: [JSONEdit.Operation], to file: SettingsFile, log: inout UndoLog) throws {
        log.record(try file.apply(operations: operations, expectedHash: try file.load().hash))
    }

    private func backupCount() throws -> Int {
        let folder = SettingsFile.backupFolderName(for: directory.file("settings.json").resolvingSymlinksInPath())
        return try FileManager.default.contentsOfDirectory(atPath: directory.file("Backups").appendingPathComponent(folder).path).count
    }

    private func externalApply(_ operation: JSONEdit.Operation, to file: SettingsFile) throws {
        let edited = try JSONEdit.apply(operation, to: try readBytes(file.url)).bytes
        try Data(edited).write(to: file.url)
    }

    @Test func undoRemovesPitotKeyAndKeepsExternalEdit() throws {
        let file = try settingsFile("settings-synthetic")
        let original = try readBytes(file.url)
        var log = UndoLog()

        try pitotApply(.set(path: ["pitotToggle"], value: .json(true)), to: file, log: &log)
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)
        let outcome = try log.undo(in: file)

        guard case .undone = outcome else {
            Issue.record("expected undone, got \(outcome)")
            return
        }
        let expected = try JSONEdit.set(["theme"], to: .json("solarized"), in: original).bytes
        #expect(try readBytes(file.url) == expected)
        #expect(log.entries.isEmpty)
    }

    @Test func undoRemovesTuiAndKeepsThemeByteExact() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()

        try pitotApply(.set(path: ["tui"], value: .json("fullscreen")), to: file, log: &log)
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)
        _ = try log.undo(in: file)

        #expect(try readBytes(file.url).text == "{\r\n  \"theme\": \"solarized\",\r\n  \"verbose\": true,\r\n  \"env\": {\r\n    \"A\": \"1\"\r\n  }\r\n}\r\n")
    }

    @Test func undoRestoresPreviousValueInPlace() throws {
        let file = try settingsFile("settings-synthetic")
        let original = try readBytes(file.url)
        var log = UndoLog()

        try pitotApply(.set(path: ["tui"], value: .json("fullscreen")), to: file, log: &log)
        try pitotApply(.remove(path: ["includeCoAuthoredBy"]), to: file, log: &log)
        try pitotApply(.set(path: ["env", "NEW_VAR"], value: .json("1")), to: file, log: &log)
        #expect(log.entries.count == 3)

        for _ in 0..<3 {
            _ = try log.undo(in: file)
        }

        #expect(try readBytes(file.url) == original)
        #expect(try log.undo(in: file) == .nothingToUndo)
    }

    @Test func undoReportsKeyChangedSinceAndDoesNotOverwrite() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(.set(path: ["tui"], value: .json("fullscreen")), to: file, log: &log)
        try externalApply(.set(path: ["tui"], value: .json("default")), to: file)
        let beforeUndo = try readBytes(file.url)

        let outcome = try log.undo(in: file)

        #expect(outcome == .changedSince(JSONEdit.Change(path: ["tui"], before: nil, after: [UInt8](#""fullscreen""#), restorePlacement: .end)))
        #expect(try readBytes(file.url) == beforeUndo)
        #expect(log.entries.count == 1)
    }

    @Test func forcedUndoOverwritesExternalChange() throws {
        let file = try settingsFile("crlf")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply(.set(path: ["theme"], value: .json("light")), to: file, log: &log)
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)

        #expect(try log.undo(in: file) == .changedSince(try #require(log.entries.last?.changes.last)))
        guard case .undone = try log.undo(in: file, force: true) else {
            Issue.record("forced undo did not apply")
            return
        }

        #expect(try readBytes(file.url) == original)
        #expect(log.entries.isEmpty)
    }

    @Test func undoReportsKeyRemovedSince() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(.set(path: ["env", "B"], value: .json("2")), to: file, log: &log)
        try externalApply(.remove(path: ["env"]), to: file)

        guard case .changedSince = try log.undo(in: file) else {
            Issue.record("expected changedSince")
            return
        }
    }

    @Test func undoReportsKeyAddedSincePitotRemovedIt() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(.remove(path: ["verbose"]), to: file, log: &log)
        try externalApply(.set(path: ["verbose"], value: .json(false)), to: file)

        guard case .changedSince = try log.undo(in: file) else {
            Issue.record("expected changedSince")
            return
        }
    }

    @Test func reformattingByAnotherToolIsNotAChange() throws {
        let url = try directory.write("settings.json", #"{"a":1}"#)
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply(.set(path: ["obj"], value: .json(["x": [1, 2]])), to: file, log: &log)
        try Data("{\n  \"a\": 1,\n  \"obj\": {\n    \"x\": [\n      1,\n      2\n    ]\n  }\n}\n".utf8).write(to: url)

        guard case .undone = try log.undo(in: file) else {
            Issue.record("expected undone")
            return
        }
        #expect(try readBytes(url).text == "{\n  \"a\": 1\n}\n")
    }

    @Test func discardLastDropsAnEntryWithoutTouchingTheFile() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(.set(path: ["tui"], value: .json("fullscreen")), to: file, log: &log)
        let before = try readBytes(file.url)

        #expect(log.discardLast()?.keys == [["tui"]])
        #expect(log.entries.isEmpty)
        #expect(try readBytes(file.url) == before)
    }

    // MARK: Groups

    @Test func groupUndoIsOneWriteThatKeepsAnOutsideEditToAnotherKey() throws {
        let file = try settingsFile("settings-synthetic")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply(
            [
                .set(path: ["tui"], value: .json("fullscreen")),
                .remove(path: ["includeCoAuthoredBy"]),
                .set(path: ["env", "NEW_VAR"], value: .json("1")),
            ],
            to: file,
            log: &log
        )
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)
        let backupsBeforeUndo = try backupCount()

        guard case .undone(let result) = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == (try JSONEdit.set(["theme"], to: .json("solarized"), in: original).bytes))
        #expect(result.changes.map(\.path) == [["env", "NEW_VAR"], ["includeCoAuthoredBy"], ["tui"]])
        #expect(try backupCount() == backupsBeforeUndo + 1)
        #expect(log.entries.isEmpty)
    }

    @Test func outsideEditToTouchedKeysIsReportedByKey() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(
            [
                .set(path: ["tui"], value: .json("fullscreen")),
                .set(path: ["theme"], value: .json("light")),
                .set(path: ["env", "B"], value: .json("2")),
            ],
            to: file,
            log: &log
        )
        try externalApply(.set(path: ["env", "B"], value: .json("3")), to: file)
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)
        let beforeUndo = try readBytes(file.url)

        #expect(try log.undoGroup(in: file) == .changedSince(keys: [["theme"], ["env", "B"]]))
        #expect(try readBytes(file.url) == beforeUndo)
        #expect(log.entries.count == 1)
    }

    @Test func forcedGroupUndoRevertsEveryKey() throws {
        let file = try settingsFile("crlf")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply([.set(path: ["tui"], value: .json("fullscreen")), .set(path: ["theme"], value: .json("light"))], to: file, log: &log)
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)

        guard case .undone = try log.undoGroup(in: file, force: true) else {
            Issue.record("forced undo did not apply")
            return
        }

        #expect(try readBytes(file.url) == original)
        #expect(log.entries.isEmpty)
    }

    @Test func groupThatCreatesAParentAndFillsItUndoesWithoutAFalseConflict() throws {
        let url = try directory.write("settings.json", "{\n  \"a\": 1\n}\n")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply([.set(path: ["env", "A"], value: .json("1")), .set(path: ["env", "B"], value: .json("1"))], to: file, log: &log)
        #expect(log.entries.last?.keys == [["env"], ["env", "B"]])

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(url).text == "{\n  \"a\": 1\n}\n")
    }

    @Test func outsideEditInsideAParentTheGroupCreatedIsReported() throws {
        let url = try directory.write("settings.json", "{\n  \"a\": 1\n}\n")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply([.set(path: ["env", "A"], value: .json("1")), .set(path: ["env", "B"], value: .json("1"))], to: file, log: &log)
        try externalApply(.set(path: ["env", "C"], value: .json("1")), to: file)

        #expect(try log.undoGroup(in: file) == .changedSince(keys: [["env"]]))
    }

    @Test func groupThatReplacesAParentAfterSettingItsChildUndoesWithoutAFalseConflict() throws {
        let file = try settingsFile("crlf")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply([.set(path: ["env", "B"], value: .json("2")), .set(path: ["env"], value: .json("flat"))], to: file, log: &log)

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == original)
    }

    @Test func sameKeyTwiceInOneGroupUndoesToTheOriginal() throws {
        let file = try settingsFile("crlf")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply([.set(path: ["tui"], value: .json("fullscreen")), .set(path: ["tui"], value: .json("default"))], to: file, log: &log)
        #expect(log.entries.last?.keys == [["tui"]])

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == original)
    }

    @Test func entriesAreGroupsWithAnIdATimeAndTheirKeys() throws {
        let file = try settingsFile("crlf")
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        var log = UndoLog(now: {
            let tick = ticks.withLock { tick in
                tick += 1
                return tick
            }
            return Date(timeIntervalSince1970: TimeInterval(tick))
        })

        try pitotApply([.set(path: ["tui"], value: .json("fullscreen")), .set(path: ["env", "B"], value: .json("2"))], to: file, log: &log)
        try pitotApply(.set(path: ["theme"], value: .json("light")), to: file, log: &log)

        #expect(log.entries.map(\.keys) == [[["tui"], ["env", "B"]], [["theme"]]])
        #expect(log.entries.map(\.date) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
        #expect(log.entries.map(\.changes.count) == [2, 1])
        #expect(Set(log.entries.map(\.id)).count == 2)
    }

    @Test func historyKeepsTheNewestHundredGroups() {
        var log = UndoLog()

        for number in 0..<105 {
            log.record(JSONEdit.Change(path: ["key\(number)"], before: nil, after: [UInt8]("1"), restorePlacement: .end))
        }

        #expect(UndoLog.historyLimit == 100)
        #expect(log.entries.count == 100)
        #expect(log.entries.first?.keys == [["key5"]])
        #expect(log.entries.last?.keys == [["key104"]])
    }

    @Test func anEmptyWriteIsNotRecorded() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()

        try pitotApply([], to: file, log: &log)

        #expect(log.entries.isEmpty)
        #expect(try log.undoGroup(in: file) == .nothingToUndo)
    }

    @Test func singleChangeUndoReportsTheChangeAtTheFirstChangedKeyOfAGroup() throws {
        let file = try settingsFile("crlf")
        var log = UndoLog()
        try pitotApply(
            [.set(path: ["tui"], value: .json("fullscreen")), .set(path: ["theme"], value: .json("light")), .set(path: ["theme"], value: .json("dim"))],
            to: file,
            log: &log
        )
        try externalApply(.set(path: ["theme"], value: .json("solarized")), to: file)

        guard case .changedSince(let change) = try log.undo(in: file) else {
            Issue.record("expected changedSince")
            return
        }

        #expect(change.path == ["theme"])
        #expect(change.after == [UInt8](#""dim""#))
    }

    // MARK: Arrays

    private let helpBlock: JSONValue = ["context": "Help", "bindings": ["ctrl+h": "help:dismiss"]]

    @Test func undoOfAnAppendedElementRestoresTheFile() throws {
        let file = try settingsFile("keybindings")
        let original = try readBytes(file.url)
        var log = UndoLog()

        try pitotApply(.appendElement(path: ["bindings"], value: .json(helpBlock)), to: file, log: &log)
        #expect(log.entries.last?.keys == [["bindings"]])
        guard case .undone = try log.undo(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == original)
    }

    @Test func groupOfElementEditsUndoesToTheOriginalBytes() throws {
        let file = try settingsFile("keybindings")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply(
            [
                .editElement(path: ["bindings"], index: 0, inner: .set(path: ["bindings", "ctrl+k"], value: .json("app:new"))),
                .editElement(path: ["bindings"], index: 1, inner: .remove(path: ["bindings", "ctrl+e"])),
                .insertElement(path: ["bindings"], index: 0, value: .json(helpBlock)),
                .replaceElement(path: ["bindings"], index: 2, value: .json(["context": "Chat", "bindings": ["ctrl+g": "chat:submit"]])),
                .removeElement(path: ["bindings"], index: 1),
            ],
            to: file,
            log: &log
        )
        #expect(log.entries.last?.keys == [["bindings"]])

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == original)
    }

    @Test func outsideEditToAnotherElementOfTheSameArrayIsReported() throws {
        let file = try settingsFile("keybindings")
        var log = UndoLog()
        let outside = JSONEdit.Operation.editElement(path: ["bindings"], index: 1, inner: .set(path: ["context"], value: .json("Help")))
        try pitotApply(
            [.editElement(path: ["bindings"], index: 0, inner: .set(path: ["bindings", "ctrl+k"], value: .json("app:new")))], to: file, log: &log)
        try externalApply(outside, to: file)
        let beforeUndo = try readBytes(file.url)

        #expect(try log.undoGroup(in: file) == .changedSince(keys: [["bindings"]]))
        #expect(try log.undoGroup(in: file, force: true) == .cannotForceArrayChange(keys: [["bindings"]]))

        #expect(try readBytes(file.url) == beforeUndo)
        #expect(log.entries.count == 1)
    }

    /// Element inverses find their element by index. After another writer prepended an element,
    /// the inverse of an append would remove the wrong one, so force is refused for that array.
    @Test func forcedUndoNeverRemovesTheWrongElement() throws {
        let file = try settingsFile("keybindings")
        var log = UndoLog()
        try pitotApply([.appendElement(path: ["bindings"], value: .json(helpBlock))], to: file, log: &log)
        let chat: JSONValue = ["context": "Chat", "bindings": ["ctrl+g": "chat:submit"]]
        try externalApply(.insertElement(path: ["bindings"], index: 0, value: .json(chat)), to: file)
        try externalApply(.editElement(path: ["bindings"], index: 1, inner: .set(path: ["context"], value: .json("Global"))), to: file)
        let beforeUndo = try readBytes(file.url)

        #expect(try log.undoGroup(in: file, force: true) == .cannotForceArrayChange(keys: [["bindings"]]))
        #expect(try log.undo(in: file, force: true) == .cannotForceArrayChange(keys: [["bindings"]]))

        #expect(try readBytes(file.url) == beforeUndo)
        #expect(log.entries.count == 1)
    }

    @Test func forcedUndoStillRevertsKeysWhenTheArrayDidNotChange() throws {
        let file = try settingsFile("keybindings")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply([.appendElement(path: ["bindings"], value: .json(helpBlock)), .set(path: ["$schema"], value: .json("mine"))], to: file, log: &log)
        try externalApply(.set(path: ["$schema"], value: .json("theirs")), to: file)

        guard case .undone = try log.undoGroup(in: file, force: true) else {
            Issue.record("forced undo did not apply")
            return
        }

        #expect(try readBytes(file.url) == original)
    }

    @Test func outsideEditOutsideTheArrayKeepsUndoWorking() throws {
        let file = try settingsFile("keybindings")
        let original = try readBytes(file.url)
        var log = UndoLog()
        try pitotApply([.appendElement(path: ["bindings"], value: .json(helpBlock))], to: file, log: &log)
        try externalApply(.set(path: ["$schema"], value: .json("x")), to: file)

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url) == (try JSONEdit.set(["$schema"], to: .json("x"), in: original).bytes))
    }

    // MARK: Never null

    @Test func undoOfAnAddedKeyRemovesItInsteadOfWritingNull() throws {
        let url = try directory.write("settings.json", "{\n  \"a\": 1\n}\n")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply([.set(path: ["outputStyle"], value: .json("Learning"))], to: file, log: &log)

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(url).text == "{\n  \"a\": 1\n}\n")
    }

    @Test func undoOfAReplacedStringPutsThatStringBack() throws {
        let url = try directory.write("settings.json", "{\n  \"outputStyle\": \"Explanatory\"\n}\n")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply([.set(path: ["outputStyle"], value: .json("Learning"))], to: file, log: &log)

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(url).text == "{\n  \"outputStyle\": \"Explanatory\"\n}\n")
    }

    @Test func undoThatWouldPutANullBackIsRefused() throws {
        let url = try directory.write("settings.json", "{\n  \"outputStyle\": null\n}\n")
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        var log = UndoLog()
        try pitotApply([.set(path: ["outputStyle"], value: .json("Learning"))], to: file, log: &log)
        let fixed = try readBytes(url)

        #expect(throws: SettingsFileError.nullValueNotAllowed(path: ["outputStyle"])) {
            try log.undoGroup(in: file)
        }

        #expect(try readBytes(url) == fixed)
        #expect(log.entries.count == 1)
    }

    private func keybindingsFile(_ text: String) throws -> SettingsFile {
        let url = try directory.write("keybindings.json", text)
        return SettingsFile(url: url, backupRoot: directory.file("Backups"), nullValuePolicy: .allow)
    }

    @Test func keybindingsFileUnbindsWithNullAndUndoPutsTheActionBack() throws {
        let original = "{\n  \"bindings\": {\n    \"ctrl+o\": \"app:toggleTodos\"\n  }\n}\n"
        let file = try keybindingsFile(original)
        var log = UndoLog()
        try pitotApply([.set(path: ["bindings", "ctrl+o"], value: .json(nil))], to: file, log: &log)
        #expect(try readBytes(file.url).text == "{\n  \"bindings\": {\n    \"ctrl+o\": null\n  }\n}\n")

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url).text == original)
    }

    @Test func keybindingsFileUndoPutsAPreviousNullBack() throws {
        let original = "{\n  \"bindings\": {\n    \"ctrl+o\": null\n  }\n}\n"
        let file = try keybindingsFile(original)
        var log = UndoLog()
        try pitotApply([.set(path: ["bindings", "ctrl+o"], value: .json("app:toggleTodos"))], to: file, log: &log)

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url).text == original)
    }

    // MARK: Created files

    private func createdFile(_ relativePath: String) throws -> (file: SettingsFile, root: URL) {
        let root = directory.file("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = SettingsFile(
            url: root.appendingPathComponent(relativePath),
            backupRoot: directory.file("Backups"),
            missingFilePolicy: .create(root: root)
        )
        return (file, root)
    }

    /// The paths of the folders an undo removed, or nil when it did not remove the created file.
    private func removedDirectories(_ outcome: UndoLog.GroupOutcome) -> [String]? {
        guard case .removedCreatedFile(let directories) = outcome else { return nil }
        return directories.map(\.path)
    }

    private func create(_ operations: [JSONEdit.Operation], in file: SettingsFile, log: inout UndoLog) throws {
        log.record(try file.apply(operations: operations, expectedHash: SettingsFile.missingFileHash))
    }

    private let createOperations: [JSONEdit.Operation] = [
        .set(path: ["model"], value: .json("opus")),
        .set(path: ["env", "A"], value: .json("1")),
    ]

    @Test func undoOfACreationRemovesTheFileAndTheFoldersItMade() throws {
        let (file, root) = try createdFile("a/.claude/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        #expect(log.entries.last?.createdFile == true)

        #expect(try removedDirectories(log.undoGroup(in: file)) == [root.appendingPathComponent("a/.claude").path, root.appendingPathComponent("a").path])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(log.entries.isEmpty)
    }

    @Test func undoOfACreationKeepsAFolderThatHoldsOtherFiles() throws {
        let (file, root) = try createdFile(".claude/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".claude/settings.json"))

        #expect(try removedDirectories(log.undoGroup(in: file)) == [])

        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
    }

    @Test func undoOfACreationKeepsAFileChangedSinceAndReversesOnlyPitotKeys() throws {
        let (file, root) = try createdFile(".claude/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        try externalApply(.set(path: ["theme"], value: .json("dark")), to: file)

        guard case .keptCreatedFile = try log.undoGroup(in: file) else {
            Issue.record("expected keptCreatedFile")
            return
        }

        #expect(try readBytes(file.url).text == "{\n  \"theme\": \"dark\"\n}\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
        #expect(log.entries.isEmpty)
    }

    @Test func undoOfACreationReportsAnOutsideEditToATouchedKey() throws {
        let (file, _) = try createdFile(".claude/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        try externalApply(.set(path: ["model"], value: .json("sonnet")), to: file)
        let beforeUndo = try readBytes(file.url)

        #expect(try log.undoGroup(in: file) == .changedSince(keys: [["model"]]))

        #expect(try readBytes(file.url) == beforeUndo)
        #expect(log.entries.count == 1)
    }

    @Test func undoOfACreationWhoseFileIsAlreadyGoneOnlyTidiesFolders() throws {
        let (file, root) = try createdFile("a/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        try FileManager.default.removeItem(at: file.url)

        #expect(try removedDirectories(log.undoGroup(in: file)) == [root.appendingPathComponent("a").path])

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }

    @Test func undoOfALaterGroupNeverRemovesTheCreatedFile() throws {
        let (file, _) = try createdFile(".claude/settings.local.json")
        var log = UndoLog()
        try create(createOperations, in: file, log: &log)
        try pitotApply([.set(path: ["theme"], value: .json("dark"))], to: file, log: &log)
        let afterCreation = "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"

        guard case .undone = try log.undoGroup(in: file) else {
            Issue.record("expected undone")
            return
        }

        #expect(try readBytes(file.url).text == afterCreation)
        #expect(log.entries.last?.createdFile == true)
    }
}
