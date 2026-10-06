import CryptoKit
import Foundation

public struct SettingsSnapshot: Sendable, Equatable {
    /// The file that was read, after resolving symlinks.
    public let url: URL
    public let bytes: [UInt8]
    /// Lowercase hex SHA-256 of `bytes`.
    public let hash: String
    public let document: JSONDocument
}

public struct SettingsWriteResult: Sendable, Equatable {
    /// The file as read back after the write.
    public let snapshot: SettingsSnapshot
    public let change: JSONEdit.Change
    /// True when the file changed after the caller loaded it, so the operation
    /// was applied to the newer content instead.
    public let rebased: Bool
    /// Copy of the content that the write replaced. Nil when the write created the file.
    public let backup: URL?
    let creation: FileCreation?

    /// True when the file did not exist and this write created it.
    public var createdFile: Bool { creation != nil }
}

/// The result of writing a list of operations as one change.
public struct SettingsGroupWriteResult: Sendable, Equatable {
    /// The file as read back after the write, or as it is when nothing was written.
    public let snapshot: SettingsSnapshot
    /// One change per operation, in the order the operations were applied.
    public let changes: [JSONEdit.Change]
    /// True when the file changed after the caller loaded it, so the list
    /// was applied to the newer content instead.
    public let rebased: Bool
    /// Copy of the content that the write replaced. Nil when the list was empty and nothing
    /// was written, or when the write created the file.
    public let backup: URL?
    let creation: FileCreation?

    /// True when the file did not exist and this write created it.
    public var createdFile: Bool { creation != nil }
    /// Folders made on the way to a created file, outermost first.
    public var createdDirectories: [URL] { creation?.directories ?? [] }
}

/// What a write that created the file made, so that undo removes exactly that.
struct FileCreation: Sendable, Equatable {
    /// SHA-256 of the bytes Pitot wrote.
    let hash: String
    /// Folders made on the way to the file, outermost first.
    let directories: [URL]
}

public enum SettingsFileError: Error, Equatable, Sendable {
    case missingFile(path: String)
    case notARegularFile(path: String)
    case emptyFile(path: String)
    case invalidJSON(JSONScanError)
    case readOnly(path: String)
    /// An operation does not fit the file, which has not changed since it was loaded. Nothing was written.
    case edit(FailedOperation)
    /// The file changed since it was loaded and an operation no longer fits the new content. Nothing was written.
    case conflict(FailedOperation)
    /// Another writer kept changing the file while Pitot tried to replace it.
    case changedDuringWrite(path: String)
    /// The written file did not parse, so the previous content was put back from `backup`.
    case restoredFromBackup(backup: String, reason: JSONScanError)
    /// The written file did not parse, but it no longer held the bytes Pitot wrote: another
    /// program wrote it after Pitot. It was left alone. `backup` holds the content from before Pitot's write.
    case restoreSkippedAnotherWriter(backup: String)
    /// The written file did not parse and putting the backup back failed. The backup is intact.
    case restoreFailed(backup: String)
    /// A value to write is `null`, or the result holds a `null` at a path where the file had none.
    /// Claude Code ignores a whole settings file when a typed key is `null`; a key is unset by removing it.
    /// `path` leads to the `null`. Array positions are numbers, and `-` stands for an appended element.
    case nullValueNotAllowed(path: [String])
    /// The file, or a folder on the way to it, lies outside the root it may be created in,
    /// for example through a symbolic link.
    case outsideRoot(path: String)
    /// The file Pitot created did not parse. If it still held Pitot's bytes it was removed with
    /// the folders made for it (`removed` is true). If another program had replaced it, it was left alone.
    case createdFileInvalid(path: String, removed: Bool, reason: JSONScanError)
    case io(operation: IOOperation, path: String, errno: Int32)

    public struct FailedOperation: Error, Equatable, Sendable {
        /// Position of the operation in the list given to `apply`. Always 0 for a single operation.
        public let index: Int
        public let reason: JSONEditError
    }

    public enum IOOperation: String, Sendable {
        case read
        case write
        case rename
        case createDirectory
        case listDirectory
        case removeOldBackup
        case removeFile
    }
}

/// Reads and safely rewrites one settings file.
///
/// A write re-reads the file, applies the key operations to whatever is there now,
/// writes a temporary file in the same folder with the same mode, syncs it, checks
/// the file did not change again, backs up the old content, and renames the
/// temporary file over the target. The result is read back and parsed. If it does
/// not parse and still holds the bytes Pitot wrote, the backup is put back. If
/// another program has replaced it since, it is left alone.
///
/// A missing file is created only when `missingFilePolicy` allows it: the new file
/// appears in one exclusive rename, so a file that another program creates first is
/// never overwritten. No backup is made for a file that did not exist.
///
/// A file with a `confinementRoot` is read and written only while it lies inside that folder
/// after following symbolic links. Files over `POSIXFile.maximumFileSize` are refused.
public struct SettingsFile: Sendable {
    public enum EmptyFilePolicy: Sendable {
        case reject
        case treatAsEmptyObject
    }

    public enum MissingFilePolicy: Sendable, Equatable {
        case error
        /// Creates the file, and missing folders on the way, inside `root` only. A folder on the way that
        /// is a symbolic link must lead inside `root` too. The file starts as `initialContent`, by default
        /// `{}` and a newline, which gives 2-space indents. It gets mode 0644, new folders 0755.
        case create(root: URL, initialContent: [UInt8]? = nil)
    }

    public enum NullValuePolicy: Sendable {
        /// For settings files, where one `null` on a typed key makes Claude Code ignore the whole file.
        case reject
        /// For files where `null` has a meaning, such as an unbound key in `keybindings.json`.
        case allow
    }

    /// The `expectedHash` to pass when the caller found no file.
    public static let missingFileHash = ""

    struct Hooks: Sendable {
        /// Replaces the bytes about to be written, to stand in for an editor bug.
        var beforeWrite: (@Sendable ([UInt8]) -> [UInt8])?
        var beforeCommit: (@Sendable (URL) -> Void)?
        var afterCommit: (@Sendable (URL) -> Void)?
        var beforeRestore: (@Sendable (URL) -> Void)?
    }

    static let maximumAttempts = 3
    static let emptyObject: [UInt8] = Array("{}\n".utf8)
    static let createdFileMode: mode_t = 0o644
    static let createdDirectoryMode: mode_t = 0o755

    public static let defaultBackupRoot = URL.applicationSupportDirectory
        .appendingPathComponent("Pitot", isDirectory: true)
        .appendingPathComponent("Backups", isDirectory: true)

    public let url: URL
    /// Backups go to `<backupRoot>/<backupFolderName>/<ISO 8601 time>.json`, and at most `backupLimit` stay there.
    public let backupRoot: URL
    public let backupLimit: Int
    public let emptyFilePolicy: EmptyFilePolicy
    public let missingFilePolicy: MissingFilePolicy
    public let nullValuePolicy: NullValuePolicy
    /// For project and local files: the project folder. Every load, write and undo first checks that the
    /// file, after following symbolic links, lies inside it, and throws `outsideRoot` otherwise.
    /// Nil for the user layer and keybindings, whose symbolic links are followed anywhere.
    public let confinementRoot: URL?
    var hooks = Hooks()

    public init(
        url: URL,
        backupRoot: URL = SettingsFile.defaultBackupRoot,
        backupLimit: Int = 20,
        emptyFilePolicy: EmptyFilePolicy = .reject,
        missingFilePolicy: MissingFilePolicy = .error,
        nullValuePolicy: NullValuePolicy = .reject,
        confinedTo confinementRoot: URL? = nil
    ) {
        self.url = url
        self.backupRoot = backupRoot
        self.backupLimit = max(1, backupLimit)
        self.emptyFilePolicy = emptyFilePolicy
        self.missingFilePolicy = missingFilePolicy
        self.nullValuePolicy = nullValuePolicy
        self.confinementRoot = confinementRoot
    }

    /// `<file name without extension>-<first 8 hex digits of the SHA-256 of the resolved path>`, so files with the
    /// same name in different folders keep separate pools. Folders named without the hash, from before this
    /// rule, are left as they are: Pitot neither prunes nor removes them.
    static func backupFolderName(for target: URL) -> String {
        "\(target.deletingPathExtension().lastPathComponent)-\(sha256(Array(target.path.utf8)).prefix(8))"
    }

    public func load() throws(SettingsFileError) -> SettingsSnapshot {
        let target = try resolveTarget().url
        return try snapshot(of: target, bytes: try POSIXFile.read(target))
    }

    /// Applies `operation` to the file. `expectedHash` is the hash the caller
    /// last loaded; a different hash on disk is not an error, the operation is
    /// re-applied to the current content and the result is marked `rebased`.
    public func apply(_ operation: JSONEdit.Operation, expectedHash: String) throws(SettingsFileError) -> SettingsWriteResult {
        try rejectNull(in: [operation])
        let write = try commit(expectedHash: expectedHash, allowingCreation: true) { (document, rebased) throws(SettingsFileError.FailedOperation) in
            let result = try Self.apply(operation, at: 0, to: document.bytes, rebased: rebased)
            return (result.bytes, result.change)
        }
        return SettingsWriteResult(snapshot: write.snapshot, change: write.edit, rebased: write.rebased, backup: write.backup, creation: write.creation)
    }

    /// Applies `operations` in order as one write: one read, one backup, one rename.
    /// If any operation does not fit, nothing is written and the error gives its index.
    /// A different hash on disk works as for a single operation: the whole list is
    /// re-applied to the current content and the result is marked `rebased`.
    /// An operation that picks an array element by index is the exception: that index
    /// may name another element now, so it fails with `staleElementIndex` instead.
    ///
    /// A missing file is created when `missingFilePolicy` allows it: the list is applied to
    /// the initial content. Pass `missingFileHash` when the caller found no file.
    /// With `nullValuePolicy` `.reject`, a list that would write `null` is refused before the
    /// file is read.
    ///
    /// An empty list is a no-op: it reads the file but writes nothing, makes no backup
    /// and needs no write permission. It never creates a file.
    public func apply(operations: [JSONEdit.Operation], expectedHash: String) throws(SettingsFileError) -> SettingsGroupWriteResult {
        try apply(operations: operations, expectedHash: expectedHash, allowingCreation: true)
    }

    /// Undo passes `allowingCreation: false`, so it never brings back a file that is gone.
    func apply(operations: [JSONEdit.Operation], expectedHash: String, allowingCreation: Bool) throws(SettingsFileError) -> SettingsGroupWriteResult {
        guard !operations.isEmpty else {
            let current = try load()
            return SettingsGroupWriteResult(snapshot: current, changes: [], rebased: current.hash != expectedHash, backup: nil, creation: nil)
        }
        try rejectNull(in: operations)
        let write = try commit(expectedHash: expectedHash, allowingCreation: allowingCreation) {
            (document, rebased) throws(SettingsFileError.FailedOperation) in
            var bytes = document.bytes
            var changes: [JSONEdit.Change] = []
            for (index, operation) in operations.enumerated() {
                let result = try Self.apply(operation, at: index, to: bytes, rebased: rebased)
                bytes = result.bytes
                changes.append(result.change)
            }
            return (bytes, changes)
        }
        return SettingsGroupWriteResult(
            snapshot: write.snapshot, changes: write.edit, rebased: write.rebased, backup: write.backup, creation: write.creation)
    }

    /// Undoes a creation: removes the file only while it still holds the bytes Pitot wrote, then the
    /// folders made for it that are empty. Returns the removed folders, deepest first, or nil when the
    /// file holds other bytes and was kept. A file that is already gone counts as removed.
    func removeCreatedFile(_ creation: FileCreation) throws(SettingsFileError) -> [URL]? {
        let target = url.resolvingSymlinksInPath()
        try checkConfinement(of: target)
        return try removeCreated(creation, at: target)
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Private

    private static func apply(
        _ operation: JSONEdit.Operation,
        at index: Int,
        to bytes: [UInt8],
        rebased: Bool
    ) throws(SettingsFileError.FailedOperation) -> JSONEdit.Result {
        if rebased, let position = operation.elementPosition {
            throw SettingsFileError.FailedOperation(index: index, reason: .staleElementIndex(path: position.path, index: position.index))
        }
        do throws(JSONEditError) {
            return try JSONEdit.apply(operation, to: bytes)
        } catch {
            throw SettingsFileError.FailedOperation(index: index, reason: error)
        }
    }

    private func rejectNull(in operations: [JSONEdit.Operation]) throws(SettingsFileError) {
        guard nullValuePolicy == .reject else { return }
        for operation in operations {
            if let path = NullGuard.firstNull(in: operation) { throw .nullValueNotAllowed(path: path) }
        }
    }

    private typealias Editing<Edit> = (JSONDocument, _ rebased: Bool) throws(SettingsFileError.FailedOperation) -> (bytes: [UInt8], edit: Edit)

    private struct Committed<Edit> {
        let snapshot: SettingsSnapshot
        let edit: Edit
        let rebased: Bool
        let backup: URL?
        let creation: FileCreation?
    }

    private enum Location {
        case existing(URL, mode: mode_t)
        case missing(root: URL, initialContent: [UInt8])
    }

    /// Runs `edit` on the current content and commits its bytes, retrying when another writer
    /// lands between the read and the rename, or creates a file where none appeared meanwhile.
    private func commit<Edit>(expectedHash: String, allowingCreation: Bool, edit: Editing<Edit>) throws(SettingsFileError) -> Committed<Edit> {
        for _ in 0..<Self.maximumAttempts {
            let committed: Committed<Edit>?
            switch try locate(allowingCreation: allowingCreation) {
            case .existing(let target, let mode):
                committed = try replace(target, mode: mode, expectedHash: expectedHash, edit: edit)
            case .missing(let root, let initialContent):
                committed = try create(within: root, initialContent: initialContent, expectedHash: expectedHash, edit: edit)
            }
            if let committed { return committed }
        }
        throw .changedDuringWrite(path: url.resolvingSymlinksInPath().path)
    }

    private func locate(allowingCreation: Bool) throws(SettingsFileError) -> Location {
        do throws(SettingsFileError) {
            let (target, mode) = try resolveTarget()
            return .existing(target, mode: mode)
        } catch .missingFile(let path) {
            guard allowingCreation, case .create(let root, let initialContent) = missingFilePolicy else { throw .missingFile(path: path) }
            return .missing(root: root, initialContent: initialContent ?? Self.emptyObject)
        }
    }

    /// Returns nil when the file changed between the read and the rename.
    private func replace<Edit>(_ target: URL, mode: mode_t, expectedHash: String, edit: Editing<Edit>) throws(SettingsFileError) -> Committed<Edit>? {
        guard access(target.path, W_OK) == 0 else {
            throw POSIXFile.isPermissionError(errno) ? .readOnly(path: target.path) : .io(operation: .write, path: target.path, errno: errno)
        }
        let current = try snapshot(of: target, bytes: try POSIXFile.read(target))
        let rebased = current.hash != expectedHash
        let edited = try prepare(current.document, rebased: rebased, edit: edit)
        let temporary = try POSIXFile.writeTemporary(edited.bytes, besides: target, mode: mode)
        let backup: URL
        do throws(SettingsFileError) {
            hooks.beforeCommit?(target)
            guard Self.sha256(try POSIXFile.read(target)) == current.hash else {
                POSIXFile.remove(temporary)
                return nil
            }
            backup = try writeBackup(current.bytes, of: target)
            try POSIXFile.rename(temporary, to: target)
        } catch {
            POSIXFile.remove(temporary)
            throw error
        }
        hooks.afterCommit?(target)
        let snapshot = try verify(target, wrote: edited.bytes, backup: backup, mode: mode)
        return Committed(snapshot: snapshot, edit: edited.edit, rebased: rebased, backup: backup, creation: nil)
    }

    /// Creates the file with the operations already applied to `initialContent`, in one exclusive
    /// rename. Returns nil when a file appeared at the path meanwhile, so the caller treats it as existing.
    private func create<Edit>(
        within root: URL,
        initialContent: [UInt8],
        expectedHash: String,
        edit: Editing<Edit>
    ) throws(SettingsFileError) -> Committed<Edit>? {
        if let confinementRoot, !POSIXFile.isPath(try POSIXFile.realPath(root), inside: try POSIXFile.realPath(confinementRoot)) {
            throw .outsideRoot(path: url.path)
        }
        guard let plan = try CreationPlan(file: url, root: root) else { return nil }
        let initial: JSONDocument
        do throws(JSONScanError) {
            initial = try JSONScanner.scan(initialContent)
        } catch {
            throw .invalidJSON(error)
        }
        let rebased = expectedHash != Self.missingFileHash
        let edited = try prepare(initial, rebased: rebased, edit: edit)
        let directories = try plan.makeDirectories()
        let target = plan.parent.resolvingSymlinksInPath().appendingPathComponent(plan.name)
        let temporary: URL
        do throws(SettingsFileError) {
            temporary = try POSIXFile.writeTemporary(edited.bytes, besides: target, mode: Self.createdFileMode)
        } catch {
            POSIXFile.removeEmptyDirectories(directories)
            throw error
        }
        let created: Bool
        do throws(SettingsFileError) {
            hooks.beforeCommit?(target)
            created = try POSIXFile.renameExclusive(temporary, to: target)
        } catch {
            POSIXFile.remove(temporary)
            POSIXFile.removeEmptyDirectories(directories)
            throw error
        }
        guard created else {
            POSIXFile.remove(temporary)
            return nil
        }
        hooks.afterCommit?(target)
        let creation = FileCreation(hash: Self.sha256(edited.bytes), directories: directories)
        let snapshot = try verifyCreated(target, creation: creation)
        return Committed(snapshot: snapshot, edit: edited.edit, rebased: rebased, backup: nil, creation: creation)
    }

    /// Runs `edit` and checks its result, before anything is written.
    private func prepare<Edit>(_ document: JSONDocument, rebased: Bool, edit: Editing<Edit>) throws(SettingsFileError) -> (bytes: [UInt8], edit: Edit) {
        let edited: (bytes: [UInt8], edit: Edit)
        do throws(SettingsFileError.FailedOperation) {
            edited = try edit(document, rebased)
        } catch {
            throw rebased ? .conflict(error) : .edit(error)
        }
        if nullValuePolicy == .reject, let path = NullGuard.newNull(in: edited.bytes, comparedWith: document) {
            throw .nullValueNotAllowed(path: path)
        }
        return (hooks.beforeWrite?(edited.bytes) ?? edited.bytes, edited.edit)
    }

    /// Reads the file back after a write. When it does not parse, the backup goes
    /// back only while the file still holds the bytes Pitot wrote.
    private func verify(_ target: URL, wrote bytes: [UInt8], backup: URL, mode: mode_t) throws(SettingsFileError) -> SettingsSnapshot {
        let written = try POSIXFile.read(target)
        do throws(JSONScanError) {
            let document = try JSONScanner.scan(written)
            return SettingsSnapshot(url: target, bytes: written, hash: Self.sha256(written), document: document)
        } catch {
            let wroteHash = Self.sha256(bytes)
            guard Self.sha256(written) == wroteHash else { throw .restoreSkippedAnotherWriter(backup: backup.path) }
            try restore(backup, to: target, mode: mode, whileHolding: wroteHash, reason: error)
        }
    }

    /// Reads a created file back. When it does not parse, it is removed only while it still holds the bytes Pitot wrote.
    private func verifyCreated(_ target: URL, creation: FileCreation) throws(SettingsFileError) -> SettingsSnapshot {
        let written = try POSIXFile.read(target)
        do throws(JSONScanError) {
            let document = try JSONScanner.scan(written)
            return SettingsSnapshot(url: target, bytes: written, hash: Self.sha256(written), document: document)
        } catch {
            let removed = try removeCreated(creation, at: target) != nil
            throw .createdFileInvalid(path: target.path, removed: removed, reason: error)
        }
    }

    private func removeCreated(_ creation: FileCreation, at target: URL) throws(SettingsFileError) -> [URL]? {
        guard try POSIXFile.remove(target, ifHolding: creation.hash) else { return nil }
        return POSIXFile.removeEmptyDirectories(creation.directories)
    }

    private func resolveTarget() throws(SettingsFileError) -> (url: URL, mode: mode_t) {
        let target = url.resolvingSymlinksInPath()
        var info = stat()
        guard stat(target.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw .missingFile(path: url.path) }
            throw .io(operation: .read, path: target.path, errno: errno)
        }
        try checkConfinement(of: target)
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile(path: target.path) }
        return (target, info.st_mode & 0o7777)
    }

    /// Throws `outsideRoot` when the file, after following symbolic links, lies outside `confinementRoot`.
    /// A file that does not exist has nothing to read or replace, so it passes.
    private func checkConfinement(of target: URL) throws(SettingsFileError) {
        guard let confinementRoot else { return }
        let resolved: String
        do throws(SettingsFileError) {
            resolved = try POSIXFile.realPath(target)
        } catch .missingFile {
            return
        }
        guard POSIXFile.isPath(resolved, inside: try POSIXFile.realPath(confinementRoot)) else { throw .outsideRoot(path: url.path) }
    }

    private func snapshot(of target: URL, bytes: [UInt8]) throws(SettingsFileError) -> SettingsSnapshot {
        do throws(JSONScanError) {
            let document = try JSONScanner.scan(bytes)
            return SettingsSnapshot(url: target, bytes: bytes, hash: Self.sha256(bytes), document: document)
        } catch .emptyInput {
            guard emptyFilePolicy == .treatAsEmptyObject else { throw .emptyFile(path: target.path) }
            do throws(JSONScanError) {
                let document = try JSONScanner.scan(Self.emptyObject)
                return SettingsSnapshot(url: target, bytes: bytes, hash: Self.sha256(bytes), document: document)
            } catch {
                throw .invalidJSON(error)
            }
        } catch {
            throw .invalidJSON(error)
        }
    }

    private func writeBackup(_ bytes: [UInt8], of target: URL) throws(SettingsFileError) -> URL {
        let folder = backupRoot.appendingPathComponent(Self.backupFolderName(for: target), isDirectory: true)
        try POSIXFile.makeDirectory(folder, mode: 0o700)
        let backup = try POSIXFile.writeUnique(bytes, in: folder, baseName: Self.timestamp(), pathExtension: "json", mode: 0o600)
        pruneBackups(in: folder)
        return backup
    }

    /// Best effort: the new backup already exists, so an old one that cannot be listed or
    /// removed stays and the write goes on.
    private func pruneBackups(in folder: URL) {
        let names: [String]
        do throws(SettingsFileError) {
            names = try POSIXFile.list(folder).filter { $0.hasSuffix(".json") }.sorted()
        } catch {
            return
        }
        for name in names.dropLast(backupLimit) {
            POSIXFile.remove(folder.appendingPathComponent(name))
        }
    }

    /// The temporary copy is written first, so the time between the last check
    /// of the file and the rename is as short as for a normal write.
    private func restore(
        _ backup: URL,
        to target: URL,
        mode: mode_t,
        whileHolding expectedHash: String,
        reason: JSONScanError
    ) throws(SettingsFileError) -> Never {
        let temporary: URL
        do throws(SettingsFileError) {
            temporary = try POSIXFile.writeTemporary(try POSIXFile.read(backup), besides: target, mode: mode)
        } catch {
            throw .restoreFailed(backup: backup.path)
        }
        defer { POSIXFile.remove(temporary) }
        hooks.beforeRestore?(target)
        let current: [UInt8]
        do throws(SettingsFileError) {
            current = try POSIXFile.read(target)
        } catch {
            throw .restoreFailed(backup: backup.path)
        }
        guard Self.sha256(current) == expectedHash else { throw .restoreSkippedAnotherWriter(backup: backup.path) }
        do throws(SettingsFileError) {
            try POSIXFile.rename(temporary, to: target)
        } catch {
            throw .restoreFailed(backup: backup.path)
        }
        throw .restoredFromBackup(backup: backup.path, reason: reason)
    }

    /// ISO 8601 basic format in UTC with microseconds, so names sort in time order.
    private static func timestamp() -> String {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        var seconds = now.tv_sec
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(
            format: "%04d%02d%02dT%02d%02d%02d.%06ldZ",
            parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
            parts.tm_hour, parts.tm_min, parts.tm_sec, now.tv_nsec / 1000
        )
    }
}

/// Thin POSIX wrappers that report `errno` as typed errors.
enum POSIXFile {
    static func isPermissionError(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM || code == EROFS
    }

    /// Settings files hold a few kilobytes. A larger file is refused with `EFBIG` before it is read.
    static let maximumFileSize = 8 * 1024 * 1024

    static func read(_ url: URL) throws(SettingsFileError) -> [UInt8] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw .missingFile(path: url.path) }
            throw .io(operation: .read, path: url.path, errno: errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .io(operation: .read, path: url.path, errno: errno) }
        guard info.st_size <= maximumFileSize else { throw .io(operation: .read, path: url.path, errno: EFBIG) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return bytes }
            if count < 0 {
                if errno == EINTR { continue }
                throw .io(operation: .read, path: url.path, errno: errno)
            }
            bytes.append(contentsOf: buffer[..<count])
            guard bytes.count <= maximumFileSize else { throw .io(operation: .read, path: url.path, errno: EFBIG) }
        }
    }

    static func writeTemporary(_ bytes: [UInt8], besides target: URL, mode: mode_t) throws(SettingsFileError) -> URL {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).pitot-\(UUID().uuidString).tmp")
        do throws(SettingsFileError) {
            try writeNew(bytes, to: temporary, mode: mode)
        } catch .io(_, _, let code) where isPermissionError(code) {
            throw .readOnly(path: folder.path)
        }
        return temporary
    }

    static func writeUnique(_ bytes: [UInt8], in folder: URL, baseName: String, pathExtension: String, mode: mode_t) throws(SettingsFileError) -> URL {
        var suffix = 0
        while true {
            let name = suffix == 0 ? "\(baseName).\(pathExtension)" : "\(baseName)-\(suffix).\(pathExtension)"
            let url = folder.appendingPathComponent(name)
            do throws(SettingsFileError) {
                try writeNew(bytes, to: url, mode: mode)
                return url
            } catch .io(_, _, EEXIST) {
                suffix += 1
            }
        }
    }

    /// Creates `url` (it must not exist), writes `bytes`, sets `mode` and flushes to disk.
    static func writeNew(_ bytes: [UInt8], to url: URL, mode: mode_t) throws(SettingsFileError) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .io(operation: .write, path: url.path, errno: errno) }
        var failure: Int32?
        if fchmod(descriptor, mode) != 0 { failure = errno }
        var offset = 0
        while failure == nil, offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), bytes.count - offset) }
            if written < 0 {
                if errno != EINTR { failure = errno }
            } else {
                offset += written
            }
        }
        if failure == nil, fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if let failure {
            Darwin.unlink(url.path)
            throw .io(operation: .write, path: url.path, errno: failure)
        }
    }

    static func rename(_ source: URL, to destination: URL) throws(SettingsFileError) {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw .io(operation: .rename, path: destination.path, errno: errno)
        }
        syncDirectory(destination.deletingLastPathComponent())
    }

    /// Renames only while nothing exists at `destination`. Returns false when something does.
    static func renameExclusive(_ source: URL, to destination: URL) throws(SettingsFileError) -> Bool {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return false }
            throw .io(operation: .rename, path: destination.path, errno: errno)
        }
        syncDirectory(destination.deletingLastPathComponent())
        return true
    }

    /// Removes `url` only while it holds bytes whose SHA-256 is `hash`. The file is moved aside and
    /// checked again there, so a file that another program writes meanwhile is never deleted.
    /// Returns true when the file is gone, also when it was missing already.
    static func remove(_ url: URL, ifHolding hash: String) throws(SettingsFileError) -> Bool {
        let bytes: [UInt8]
        do throws(SettingsFileError) {
            bytes = try read(url)
        } catch .missingFile {
            return true
        }
        guard SettingsFile.sha256(bytes) == hash else { return false }
        let aside = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pitot-\(UUID().uuidString).tmp")
        guard Darwin.rename(url.path, aside.path) == 0 else {
            if errno == ENOENT { return true }
            throw .io(operation: .rename, path: url.path, errno: errno)
        }
        guard SettingsFile.sha256(try read(aside)) == hash else {
            guard try renameExclusive(aside, to: url) else { throw .io(operation: .rename, path: aside.path, errno: EEXIST) }
            return false
        }
        try unlink(aside, operation: .removeFile)
        syncDirectory(url.deletingLastPathComponent())
        return true
    }

    /// Removes each folder that is empty, deepest first, and stops at the first one that is not.
    /// Returns the folders it removed. Best effort: a folder that stays is not an error.
    @discardableResult
    static func removeEmptyDirectories(_ directories: [URL]) -> [URL] {
        var removed: [URL] = []
        for directory in directories.reversed() {
            if rmdir(directory.path) == 0 {
                removed.append(directory)
            } else if errno != ENOENT {
                break
            }
        }
        return removed
    }

    /// True when the real path `path` is `root` or lies below it.
    static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func realPath(_ url: URL) throws(SettingsFileError) -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else {
            if errno == ENOENT { throw .missingFile(path: url.path) }
            throw .io(operation: .read, path: url.path, errno: errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Best effort: the rename already happened and the file content is synced,
    /// so a failed directory sync only weakens durability after a power loss.
    private static func syncDirectory(_ folder: URL) {
        let descriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }

    /// Removes a temporary file that may already have been renamed away.
    static func remove(_ url: URL) {
        Darwin.unlink(url.path)
    }

    static func unlink(_ url: URL, operation: SettingsFileError.IOOperation) throws(SettingsFileError) {
        guard Darwin.unlink(url.path) == 0 || errno == ENOENT else {
            throw .io(operation: operation, path: url.path, errno: errno)
        }
    }

    static func makeDirectory(_ url: URL, mode: mode_t) throws(SettingsFileError) {
        var info = stat()
        if stat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw .io(operation: .createDirectory, path: url.path, errno: ENOTDIR) }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path { try makeDirectory(parent, mode: mode) }
        guard mkdir(url.path, mode) == 0 || errno == EEXIST else {
            throw .io(operation: .createDirectory, path: url.path, errno: errno)
        }
    }

    static func list(_ folder: URL) throws(SettingsFileError) -> [String] {
        guard let directory = opendir(folder.path) else {
            throw .io(operation: .listDirectory, path: folder.path, errno: errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}

/// Where a missing file will be created: checked to stay inside `root`, with the folders still to make.
struct CreationPlan {
    /// The folder that will hold the file, as named in the file's path.
    let parent: URL
    let name: String
    /// Folders to make, outermost first.
    let missing: [URL]

    /// Nil when a regular file exists at `file` by now. Throws `outsideRoot` when `file` is not under
    /// `root`, or a folder on the way is a symbolic link that leads outside it.
    init?(file: URL, root: URL) throws(SettingsFileError) {
        let file = file.standardizedFileURL
        let root = root.standardizedFileURL
        let components = file.pathComponents
        let rootComponents = root.pathComponents
        guard components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else {
            throw .outsideRoot(path: file.path)
        }
        let rootPath = try POSIXFile.realPath(root)
        var folder = root
        var missing: [URL] = []
        for component in components[rootComponents.count..<(components.count - 1)] {
            folder = folder.appendingPathComponent(component, isDirectory: true)
            if missing.isEmpty, try Self.exists(folder, insideRealPath: rootPath) { continue }
            missing.append(folder)
        }
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile(path: file.path) }
            return nil
        }
        guard errno == ENOENT else { throw .io(operation: .read, path: file.path, errno: errno) }
        parent = folder
        name = file.lastPathComponent
        self.missing = missing
    }

    /// False when `folder` does not exist. Throws when it is not a folder, or is a symbolic link that leads outside `rootPath`.
    private static func exists(_ folder: URL, insideRealPath rootPath: String) throws(SettingsFileError) -> Bool {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            guard errno == ENOENT else { throw .io(operation: .read, path: folder.path, errno: errno) }
            return false
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return true
        case S_IFLNK:
            guard POSIXFile.isPath(try POSIXFile.realPath(folder), inside: rootPath) else { throw .outsideRoot(path: folder.path) }
            guard stat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw .io(operation: .createDirectory, path: folder.path, errno: ENOTDIR)
            }
            return true
        default:
            throw .io(operation: .createDirectory, path: folder.path, errno: ENOTDIR)
        }
    }

    /// Makes the missing folders. Returns the ones this call made, outermost first.
    func makeDirectories() throws(SettingsFileError) -> [URL] {
        var made: [URL] = []
        for folder in missing {
            if mkdir(folder.path, SettingsFile.createdDirectoryMode) == 0 {
                made.append(folder)
                continue
            }
            let code = errno
            var info = stat()
            guard code == EEXIST, lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                POSIXFile.removeEmptyDirectories(made)
                throw .io(operation: .createDirectory, path: folder.path, errno: code)
            }
        }
        return made
    }
}

/// Finds `null` values. One `null` on a typed key makes Claude Code ignore the whole settings file.
enum NullGuard {
    /// The path to the first `null` in the value an operation writes. Array positions are numbers,
    /// and `-` stands for an appended element.
    static func firstNull(in operation: JSONEdit.Operation) -> [String]? {
        switch operation {
        case .set(let path, let value, _):
            firstNull(in: value).map { path + $0 }
        case .remove, .removeElement:
            nil
        case .appendElement(let path, let value):
            firstNull(in: value).map { path + ["-"] + $0 }
        case .insertElement(let path, let index, let value), .replaceElement(let path, let index, let value):
            firstNull(in: value).map { path + [String(index)] + $0 }
        case .editElement(let path, let index, let inner):
            firstNull(in: inner).map { path + [String(index)] + $0 }
        }
    }

    /// The first `null` in `bytes` at a path where `original` has none. Bytes that do not scan
    /// have no answer here; reading the file back after the write reports them.
    static func newNull(in bytes: [UInt8], comparedWith original: JSONDocument) -> [String]? {
        let result: JSONDocument
        do throws(JSONScanError) {
            result = try JSONScanner.scan(bytes)
        } catch {
            return nil
        }
        let existing = Set(nullPaths(in: original.decode(original.root)).map(utf16))
        return nullPaths(in: result.decode(result.root)).first { !existing.contains(utf16($0)) }
    }

    /// A raw value that does not scan has no `null` to find; the editor reports it.
    private static func firstNull(in value: JSONEdit.Value) -> [String]? {
        switch value {
        case .json(let json):
            return nullPaths(in: json).first
        case .raw(let raw):
            do throws(JSONScanError) {
                let document = try JSONScanner.scan(raw)
                return nullPaths(in: document.decode(document.root)).first
            } catch {
                return nil
            }
        }
    }

    private static func nullPaths(in value: JSONValue, prefix: [String] = []) -> [[String]] {
        switch value {
        case .null: [prefix]
        case .bool, .number, .string: []
        case .array(let elements): elements.enumerated().flatMap { nullPaths(in: $1, prefix: prefix + [String($0)]) }
        case .object(let members): members.flatMap { nullPaths(in: $0.value, prefix: prefix + [$0.key]) }
        }
    }

    /// Keys compare as UTF-16 code units, like JavaScript.
    private static func utf16(_ path: [String]) -> [[UInt16]] {
        path.map { Array($0.utf16) }
    }
}
