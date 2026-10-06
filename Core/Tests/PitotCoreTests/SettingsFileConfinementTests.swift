import Foundation
import Testing

@testable import PitotCore

/// A cloned repository can commit `.claude/settings.local.json` as a symbolic link to any file the
/// user owns. A file confined to its project folder never reads or writes through such a link.
@Suite("Confinement to a project folder")
struct SettingsFileConfinementTests {
    let directory: TemporaryDirectory
    let project: URL
    let outsideFile: URL
    let outsideText = "{\n  \"oauthAccount\": \"secret\"\n}\n"

    init() throws {
        directory = try TemporaryDirectory()
        project = directory.file("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.file("home"), withIntermediateDirectories: false)
        outsideFile = try directory.write("home/.claude.json", outsideText)
    }

    private var localURL: URL { project.appendingPathComponent(".claude/settings.local.json") }

    private func confinedFile(_ url: URL? = nil, missingFilePolicy: SettingsFile.MissingFilePolicy = .error) -> SettingsFile {
        SettingsFile(url: url ?? localURL, backupRoot: directory.file("Backups"), missingFilePolicy: missingFilePolicy, confinedTo: project)
    }

    private func expectOutsideFileUntouched() throws {
        #expect(try readBytes(outsideFile).text == outsideText)
        #expect(!FileManager.default.fileExists(atPath: directory.file("Backups").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.file("home").path) == [".claude.json"])
    }

    private let model = JSONEdit.Operation.set(path: ["model"], value: .json("opus"))

    @Test func linkToAFileOutsideTheProjectIsRefusedForLoadAndApply() throws {
        try FileManager.default.createSymbolicLink(at: localURL, withDestinationURL: outsideFile)
        let file = confinedFile()

        #expect(throws: SettingsFileError.outsideRoot(path: localURL.path)) { try file.load() }
        #expect(throws: SettingsFileError.outsideRoot(path: localURL.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }
        #expect(throws: SettingsFileError.outsideRoot(path: localURL.path)) {
            try file.apply(model, expectedHash: SettingsFile.missingFileHash)
        }

        try expectOutsideFileUntouched()
    }

    @Test func linkMadeAfterAWriteIsRefusedByUndo() throws {
        try Data("{\n  \"a\": 1\n}\n".utf8).write(to: localURL)
        let file = confinedFile()
        var log = UndoLog()
        log.record(try file.apply(operations: [model], expectedHash: try file.load().hash))
        try FileManager.default.removeItem(at: directory.file("Backups"))
        try FileManager.default.removeItem(at: localURL)
        try FileManager.default.createSymbolicLink(at: localURL, withDestinationURL: outsideFile)

        #expect(throws: SettingsFileError.outsideRoot(path: localURL.path)) { try log.undoGroup(in: file, force: true) }

        try expectOutsideFileUntouched()
        #expect(log.entries.count == 1)
    }

    @Test func linkMadeAfterACreationIsRefusedByUndo() throws {
        let file = confinedFile(missingFilePolicy: .create(root: project))
        var log = UndoLog()
        let result = try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        log.record(result)
        try FileManager.default.removeItem(at: localURL)
        try Data(result.snapshot.bytes).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: localURL, withDestinationURL: outsideFile)

        #expect(throws: SettingsFileError.outsideRoot(path: localURL.path)) { try log.undoGroup(in: file) }

        #expect(try readBytes(outsideFile) == result.snapshot.bytes)
    }

    @Test func folderLinkOutOfTheProjectIsRefused() throws {
        let outsideFolder = directory.file("home/dotclaude")
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: false)
        let target = try directory.write("home/dotclaude/settings.local.json", outsideText)
        let link = project.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFolder)
        let url = link.appendingPathComponent("settings.local.json")
        let file = confinedFile(url)

        #expect(throws: SettingsFileError.outsideRoot(path: url.path)) { try file.load() }
        #expect(throws: SettingsFileError.outsideRoot(path: url.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }

        #expect(try readBytes(target).text == outsideText)
        #expect(!FileManager.default.fileExists(atPath: directory.file("Backups").path))
    }

    @Test func linkToAFileInsideTheProjectIsFollowed() throws {
        let shared = try directory.write("project/shared.json", "{\n  \"a\": 1\n}\n")
        try FileManager.default.createSymbolicLink(at: localURL, withDestinationURL: shared)
        let file = confinedFile()

        _ = try file.apply(operations: [model], expectedHash: try file.load().hash)

        #expect(try readBytes(shared).text == "{\n  \"a\": 1,\n  \"model\": \"opus\"\n}\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: localURL.path) == shared.path)
    }

    @Test func creationThroughAWiderCreateRootIsStillConfined() throws {
        let url = directory.file("elsewhere/settings.json")
        let file = SettingsFile(
            url: url,
            backupRoot: directory.file("Backups"),
            missingFilePolicy: .create(root: directory.url),
            confinedTo: project
        )

        #expect(throws: SettingsFileError.outsideRoot(path: url.path)) {
            try file.apply(operations: [model], expectedHash: SettingsFile.missingFileHash)
        }

        #expect(!FileManager.default.fileExists(atPath: directory.file("elsewhere").path))
    }

    @Test func userLayerWithoutAConfinementStillFollowsItsLink() throws {
        let link = directory.file("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        let file = SettingsFile(url: link, backupRoot: directory.file("Backups"))

        _ = try file.apply(operations: [model], expectedHash: try file.load().hash)

        #expect(try readBytes(outsideFile).text == "{\n  \"oauthAccount\": \"secret\",\n  \"model\": \"opus\"\n}\n")
    }
}
