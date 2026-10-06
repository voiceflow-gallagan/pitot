import Foundation
import Testing

@testable import PitotCore

/// A typed key set to `null` makes Claude Code drop the whole settings file (rule 8 in `Core/MERGE-RULES.md`).
@Suite("Null guard")
struct SettingsFileNullGuardTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func file(_ text: String, nullValuePolicy: SettingsFile.NullValuePolicy = .reject) throws -> SettingsFile {
        let url = try directory.write("settings.json", text)
        return SettingsFile(url: url, backupRoot: directory.file("Backups"), nullValuePolicy: nullValuePolicy)
    }

    private func expectRefused(_ operations: [JSONEdit.Operation], at path: [String], in text: String) throws {
        let file = try file(text)
        #expect(throws: SettingsFileError.nullValueNotAllowed(path: path)) {
            try file.apply(operations: operations, expectedHash: try file.load().hash)
        }
        #expect(try readBytes(file.url).text == text)
        #expect(!FileManager.default.fileExists(atPath: directory.file("Backups").path))
    }

    @Test func refusesSettingAKeyToNull() throws {
        try expectRefused([.set(path: ["outputStyle"], value: .json(nil))], at: ["outputStyle"], in: "{\"a\": 1}\n")
    }

    @Test func refusesNullNestedInObjectsAndArrays() throws {
        let value: JSONValue = ["network": ["allowedDomains": ["a.com", nil]]]
        try expectRefused([.set(path: ["sandbox"], value: .json(value))], at: ["sandbox", "network", "allowedDomains", "1"], in: "{}\n")
    }

    @Test func refusesNullInARawValue() throws {
        try expectRefused([.set(path: ["env"], value: .raw([UInt8]("{\"A\": \"1\", \"B\": null}")))], at: ["env", "B"], in: "{}\n")
    }

    @Test func refusesNullInElementOperations() throws {
        let text = "{\"list\": [1, 2], \"objects\": [{\"a\": 1}]}\n"
        try expectRefused([.appendElement(path: ["list"], value: .json(nil))], at: ["list", "-"], in: text)
        try expectRefused([.insertElement(path: ["list"], index: 1, value: .json(nil))], at: ["list", "1"], in: text)
        try expectRefused([.replaceElement(path: ["list"], index: 0, value: .json([nil]))], at: ["list", "0", "0"], in: text)
        try expectRefused(
            [.editElement(path: ["objects"], index: 0, inner: .set(path: ["a"], value: .json(nil)))],
            at: ["objects", "0", "a"],
            in: text
        )
    }

    @Test func checksEveryOperationBeforeTouchingTheFile() throws {
        try expectRefused(
            [.set(path: ["a"], value: .json(2)), .remove(path: ["missing"]), .set(path: ["b"], value: .json(["c": nil]))],
            at: ["b", "c"],
            in: "{\"a\": 1}\n"
        )
    }

    @Test func singleOperationIsCheckedToo() throws {
        let file = try file("{}\n")
        #expect(throws: SettingsFileError.nullValueNotAllowed(path: ["a"])) {
            try file.apply(.set(path: ["a"], value: .json(nil)), expectedHash: try file.load().hash)
        }
    }

    @Test func aNullAlreadyInTheFileDoesNotBlockOtherEdits() throws {
        let file = try file("{\"env\": {\"X\": null}, \"a\": 1}\n")

        _ = try file.apply(operations: [.set(path: ["a"], value: .json(2))], expectedHash: try file.load().hash)

        #expect(try readBytes(file.url).text == "{\"env\": {\"X\": null}, \"a\": 2}\n")
    }

    /// The check on the result compares paths, so an element edit that moves an existing null
    /// to another index is refused too. A settings file with a null in a list is already broken.
    @Test func resultWithANullAtANewPathIsRefused() throws {
        try expectRefused([.insertElement(path: ["list"], index: 0, value: .json(0))], at: ["list", "1"], in: "{\"list\": [null]}\n")
    }

    @Test func removingAKeyIsHowAValueIsUnset() throws {
        let file = try file("{\"outputStyle\": \"Explanatory\", \"a\": 1}\n")

        _ = try file.apply(operations: [.remove(path: ["outputStyle"])], expectedHash: try file.load().hash)

        #expect(try readBytes(file.url).text == "{\"a\": 1}\n")
    }

    @Test func allowPolicyWritesNullForFilesThatUseIt() throws {
        let original = "{\"bindings\": {}}\n"
        let file = try file(original, nullValuePolicy: .allow)
        let unbind = JSONEdit.Operation.set(path: ["bindings", "ctrl+o"], value: .json(nil))

        _ = try file.apply(operations: [unbind], expectedHash: try file.load().hash)

        #expect(try readBytes(file.url) == (try JSONEdit.apply(unbind, to: [UInt8](original)).bytes))
    }
}
