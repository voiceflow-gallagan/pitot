import PitotCore
import Foundation

/// Plain-language text for every error Core can report.
enum ErrorText {
    /// `operations` is the list given to `apply`, so a failed operation can be named by its key.
    static func describe(_ error: SettingsFileError, operations: [JSONEdit.Operation] = []) -> String {
        switch error {
        case .missingFile(let path):
            "The settings file does not exist: \(path)"
        case .notARegularFile(let path):
            "This is not a regular file: \(path)"
        case .emptyFile(let path):
            "The settings file is empty: \(path)"
        case .invalidJSON(let reason):
            "The settings file is not valid JSON: \(describe(reason))."
        case .readOnly(let path):
            "Pitot has no permission to write \(path)."
        case .edit(let failed):
            "\(name(of: failed, in: operations)) does not fit the file: \(describe(failed.reason)). Nothing was written."
        case .conflict(let failed):
            "The file changed while you were editing, and \(name(of: failed, in: operations).lowercasedFirst) no longer fits: "
                + "\(describe(failed.reason)). Nothing was written."
        case .changedDuringWrite(let path):
            "Another program kept changing \(path). Nothing was written. Try again."
        case .restoredFromBackup(let backup, let reason):
            "The written file was not valid JSON (\(describe(reason))). Pitot put the previous content back from \(backup)."
        case .restoreSkippedAnotherWriter(let backup):
            "The written file was not valid JSON, and another program changed it right after Pitot wrote it. "
                + "Pitot left that program's file alone. The content from before Pitot's write is in \(backup)."
        case .restoreFailed(let backup):
            "The written file was not valid JSON and putting the old content back failed. Your backup is intact: \(backup)"
        case .nullValueNotAllowed(let path):
            "Pitot will not write null at \(path.joined(separator: ".")). Claude Code ignores a whole settings file "
                + "that holds null for a setting. Nothing was written."
        case .outsideRoot:
            outsideProject
        case .createdFileInvalid(let path, let removed, let reason):
            removed
                ? "The file Pitot created at \(path) was not valid JSON (\(describe(reason))), so Pitot removed it again."
                : "The file Pitot created at \(path) was not valid JSON (\(describe(reason))). "
                    + "Another program changed it right after, so Pitot left it alone."
        case .io(.read, _, EFBIG):
            tooLarge
        case .io(let operation, let path, let code):
            "Could not \(verb(operation)) \(path): \(String(cString: strerror(code)))."
        }
    }

    static func describe(_ error: JSONEditError) -> String {
        switch error {
        case .invalidJSON(let reason): "the file is not valid JSON (\(describe(reason)))"
        case .invalidRawValue(let reason): "the new value is not valid JSON (\(describe(reason)))"
        case .emptyPath: "the key name is empty"
        case .notAnObject(let path): path.isEmpty ? "the top level of the file is not an object" : "\(path.joined(separator: ".")) is not an object"
        case .keyNotFound(let path): "\(path.joined(separator: ".")) is not in the file"
        case .notAnArray(let path): "\(path.joined(separator: ".")) is not a list"
        case .indexOutOfRange(let path, let index, let count): "\(path.joined(separator: ".")) has \(count) items, so there is no item \(index + 1)"
        case .elementNotAnObject(let path, let index): "item \(index + 1) of \(path.joined(separator: ".")) is not an object"
        case .staleElementIndex(let path, _): "\(path.joined(separator: ".")) changed in the file since Pitot read it"
        case .producedInvalidJSON: "the edit produced invalid JSON, which is a bug in Pitot"
        }
    }

    static func describe(_ error: JSONScanError) -> String {
        switch error {
        case .emptyInput: "the file is empty"
        case .byteOrderMark: "the file starts with a byte order mark"
        case .invalidUTF8(let offset): "invalid UTF-8 text at byte \(offset)"
        case .comment(let offset): "a comment at byte \(offset), and JSON does not allow comments"
        case .trailingComma(let offset): "a trailing comma at byte \(offset)"
        case .duplicateKey(let offset): "a key that appears twice in one object, at byte \(offset)"
        case .unterminatedString(let offset): "a string that is never closed, starting at byte \(offset)"
        case .invalidEscape(let offset): "an invalid escape sequence at byte \(offset)"
        case .controlCharacterInString(let offset): "a control character inside a string at byte \(offset)"
        case .invalidNumber(let offset): "an invalid number at byte \(offset)"
        case .unexpectedByte(let offset): "an unexpected character at byte \(offset)"
        case .unexpectedEnd: "the file ends too early"
        case .trailingContent(let offset): "extra content after the JSON, at byte \(offset)"
        case .nestingTooDeep(let offset): "nesting deeper than \(JSONScanner.maximumDepth) levels at byte \(offset)"
        }
    }

    static func describe(_ error: CatalogError) -> String {
        switch error {
        case .malformed(let path, let reason):
            "The built-in list of settings is malformed at \(path.isEmpty ? "the top level" : path): \(reason)"
        case .lintFailed(let issues):
            (["The built-in list of settings failed \(issues.count) check\(issues.count == 1 ? "" : "s"):"] + issues.map { "- \($0.description)" })
                .joined(separator: "\n")
        }
    }

    static func describe(_ error: OnboardingError) -> String {
        switch error {
        case .malformed(let path, let reason):
            "The setup questions are malformed at \(path.isEmpty ? "the top level" : path): \(reason)"
        case .lintFailed(let issues):
            (["The setup questions failed \(issues.count) check\(issues.count == 1 ? "" : "s"):"] + issues.map { "- \($0.description)" })
                .joined(separator: "\n")
        }
    }

    static func describe(_ error: KeybindingsCatalogError) -> String {
        switch error {
        case .malformed(let path, let reason):
            "The keybindings table is malformed at \(path.isEmpty ? "the top level" : path): \(reason)"
        case .lintFailed(let issues):
            (["The keybindings table failed \(issues.count) check\(issues.count == 1 ? "" : "s"):"] + issues.map { "- \($0.description)" })
                .joined(separator: "\n")
        }
    }

    static func describe(_ error: KeybindingsFileError) -> String {
        switch error {
        case .rootNotObject: "the top level is not a JSON object"
        case .bindingsNotArray: "bindings is not a list"
        case .blockNotObject(let index): "entry \(index + 1) of bindings is not an object"
        case .contextMissing(let block): "entry \(block + 1) of bindings has no context"
        case .contextNotString(let block): "the context of entry \(block + 1) is not text"
        case .blockBindingsNotObject(let block): "the bindings of entry \(block + 1) are not an object"
        case .actionNotStringOrNull(let block, let key): "the action for \(key) in entry \(block + 1) is not text or null"
        case .initialContentInvalid(let reason): "the header for a new keybindings file is not valid JSON (\(describe(reason)))"
        }
    }

    static let outsideProject = "This file is a link that points outside the project. Pitot will not read or write it."
    static let tooLarge = "This file is larger than 8 MB. Pitot will not open it."

    static func cannotForce(_ keys: [[String]]) -> String {
        "This change cannot be forced because the list changed. Undo it by hand: " + keys.map { $0.joined(separator: ".") }.joined(separator: ", ")
    }

    private static func name(of failed: SettingsFileError.FailedOperation, in operations: [JSONEdit.Operation]) -> String {
        guard operations.indices.contains(failed.index) else { return "Change \(failed.index + 1)" }
        return "The change to \(operations[failed.index].path.joined(separator: "."))"
    }

    private static func verb(_ operation: SettingsFileError.IOOperation) -> String {
        switch operation {
        case .read: "read"
        case .write: "write"
        case .rename: "replace"
        case .createDirectory: "create the folder"
        case .listDirectory: "list the folder"
        case .removeOldBackup: "remove the old backup"
        case .removeFile: "remove"
        }
    }
}

extension String {
    /// Lowercases the first letter unless the second is uppercase too, so names such as `JSON` stay as they are.
    var lowercasedFirst: String {
        guard let first, let second = dropFirst().first, !second.isUppercase else { return self }
        return first.lowercased() + dropFirst()
    }
}
