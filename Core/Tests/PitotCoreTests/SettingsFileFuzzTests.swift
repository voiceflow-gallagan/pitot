import Foundation
import Testing

@testable import PitotCore

@Suite("Group write fuzz")
struct SettingsFileFuzzTests {
    /// Takes about 15 seconds: every successful list costs two real writes, each with two `F_FULLFSYNC` calls.
    /// The generator writes `null` values, so the file allows them: the null guard has its own tests.
    @Test("1000 random lists of 1 to 5 operations write all or nothing, keep untouched bytes and undo as one group")
    func randomLists() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("settings.json")
        let backups = directory.file("Backups").appendingPathComponent(SettingsFile.backupFolderName(for: url.resolvingSymlinksInPath()))
        let file = SettingsFile(url: url, backupRoot: directory.file("Backups"), backupLimit: 2, nullValuePolicy: .allow)
        let root = directory.file("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let creating = SettingsFile(
            url: root.appendingPathComponent("new/.claude/settings.json"),
            backupRoot: directory.file("Backups"),
            missingFilePolicy: .create(root: root),
            nullValuePolicy: .allow
        )
        var random = SplitMix64(seed: 0x6A7E_B10C)
        var failedLists = 0
        for iteration in 0..<1000 {
            let context = "iteration \(iteration)"
            if iteration % 5 == 0 {
                failedLists += try createFromMissingFile(with: creating, root: root, using: &random, context: context) ? 1 : 0
                continue
            }
            let model = FuzzGenerator.object(depth: 0, using: &random)
            let original = [UInt8](FuzzWriter(style: FuzzStyle.random(using: &random)).document(model))
            try Data(original).write(to: url)
            let list = FuzzList.random(for: model, using: &random)
            let backupsBefore = try backupNames(in: backups)

            if let failure = list.failure {
                failedLists += 1
                #expect(throws: SettingsFileError.edit(failure), "\(context): error") {
                    try file.apply(operations: list.operations, expectedHash: try file.load().hash)
                }
                #expect(try readBytes(url) == original, "\(context): file changed")
                #expect(try backupNames(in: backups) == backupsBefore, "\(context): backup made")
                continue
            }

            let result = try file.apply(operations: list.operations, expectedHash: try file.load().hash)
            let before = try JSONScanner.scan(original)
            let after = try JSONScanner.scan(try readBytes(url))
            #expect(result.changes.count == list.operations.count, "\(context): change count")
            #expect(after.value(at: []) == list.expected, "\(context): decoded result differs from model")
            expectUntouchedBytesAndOrder(before: before, after: after, touched: list.operations.map(\.path), context: context)

            var log = UndoLog()
            log.record(result)
            let outcome = try log.undoGroup(in: file)
            guard case .undone = outcome else {
                Issue.record("\(context): expected undone, got \(outcome)")
                continue
            }
            #expect(try JSONScanner.scan(try readBytes(url)).value(at: []) == model, "\(context): undo did not restore the original")
        }
        #expect(try leftoverTemporaryFiles(in: directory.url).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(failedLists > 150, "too few failing lists to test all or nothing")
    }

    /// Starts from no file: a failing list creates nothing, a good one creates the file and its
    /// folders, and undo removes all of them again. Returns true when the list was made to fail.
    private func createFromMissingFile(with file: SettingsFile, root: URL, using random: inout SplitMix64, context: String) throws -> Bool {
        let list = FuzzList.random(for: [:], using: &random)
        let folder = root.appendingPathComponent("new")
        if let failure = list.failure {
            #expect(throws: SettingsFileError.edit(failure), "\(context): error") {
                try file.apply(operations: list.operations, expectedHash: SettingsFile.missingFileHash)
            }
            #expect(!FileManager.default.fileExists(atPath: folder.path), "\(context): folder made by a failing list")
            return true
        }
        let result = try file.apply(operations: list.operations, expectedHash: SettingsFile.missingFileHash)
        #expect(result.createdFile, "\(context): not created")
        #expect(try JSONScanner.scan(try readBytes(file.url)).value(at: []) == list.expected, "\(context): decoded result differs from model")

        var log = UndoLog()
        log.record(result)
        let outcome = try log.undoGroup(in: file)
        guard case .removedCreatedFile(let directories) = outcome else {
            Issue.record("\(context): expected removedCreatedFile, got \(outcome)")
            try FileManager.default.removeItem(at: folder)
            return false
        }
        #expect(directories.map(\.lastPathComponent) == [".claude", "new"], "\(context): removed folders")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "\(context): folder left after undo")
        return false
    }

    private func expectUntouchedBytesAndOrder(before: JSONDocument, after: JSONDocument, touched: [[String]], context: String) {
        let isTouched = { (path: [String]) in touched.contains { $0.isPrefix(of: path) || path.isPrefix(of: $0) } }
        for path in memberPaths(in: before.root, document: before, prefix: []) where !isTouched(path) {
            let original = before.node(at: path).map(before.rawBytes)
            let edited = after.node(at: path).map(after.rawBytes)
            #expect(original == edited, "\(context): bytes of \(path) changed")
        }
        for objectPath in objectPaths(in: before.root, document: before, prefix: []) where !touched.contains(where: { $0.isPrefix(of: objectPath) }) {
            let untouched = (before.node(at: objectPath)?.members ?? []).map(\.key).filter { !isTouched(objectPath + [$0]) }
            let resultKeys = (after.node(at: objectPath)?.members ?? []).map(\.key).filter { key in
                untouched.contains { Array($0.utf16) == Array(key.utf16) }
            }
            #expect(resultKeys == untouched, "\(context): key order of \(objectPath) changed")
        }
    }

    private func backupNames(in folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func leftoverTemporaryFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
    }
}

/// A random operation list built against the evolving model, so every operation fits
/// except, in about a quarter of the lists, one that is made to fail.
struct FuzzList {
    var operations: [JSONEdit.Operation] = []
    var failure: SettingsFileError.FailedOperation?
    /// The model after every operation, when none fails.
    var expected: JSONValue

    static func random(for model: JSONValue, using random: inout SplitMix64) -> FuzzList {
        let count = Int.random(in: 1...5, using: &random)
        let failingIndex = Int.random(in: 0..<4, using: &random) == 0 ? Int.random(in: 0..<count, using: &random) : nil
        var list = FuzzList(expected: model)
        for index in 0..<count {
            if index == failingIndex {
                let (operation, reason) = failingOperation(for: list.expected, using: &random)
                list.operations.append(operation)
                list.failure = SettingsFileError.FailedOperation(index: index, reason: reason)
            } else {
                let operation = FuzzGenerator.operation(for: list.expected, using: &random)
                list.operations.append(operation)
                list.expected = FuzzModel.apply(operation, to: list.expected)
            }
        }
        return list
    }

    private static func failingOperation(for model: JSONValue, using random: inout SplitMix64) -> (JSONEdit.Operation, JSONEditError) {
        let scalars = FuzzModel.memberPaths(model).filter { path in
            guard let value = FuzzModel.lookup(path, in: model), case .object = value else { return true }
            return false
        }
        switch Int.random(in: 0..<3, using: &random) {
        case 0:
            return (.set(path: [], value: .json(1)), .emptyPath)
        case 1:
            if let path = scalars.randomElement(using: &random) {
                return (.set(path: path + ["below"], value: .json(1)), .notAnObject(path: path))
            }
            return (.remove(path: ["missing"]), .keyNotFound(path: ["missing"]))
        default:
            let parent = FuzzModel.objectPaths(model).randomElement(using: &random) ?? []
            return (.remove(path: parent + ["missing"]), .keyNotFound(path: parent + ["missing"]))
        }
    }
}
