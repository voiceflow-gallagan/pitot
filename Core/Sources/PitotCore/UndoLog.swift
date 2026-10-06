import Foundation

/// Undo for changes Pitot made, one group per write. Undo applies the inverse
/// key operations to the file as it is now, so edits made by other tools since
/// then survive. It is not a restore of an old copy of the file.
public struct UndoLog: Sendable {
    /// The changes of one write, undone together.
    public struct Group: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let date: Date
        /// One change per operation, in the order they were applied.
        public let changes: [JSONEdit.Change]
        /// One per touched path, in the order the paths were first touched.
        let expectations: [Expectation]
        let creation: FileCreation?

        /// Each path the group touched, once, in the order first touched.
        public var keys: [[String]] { expectations.map(\.path) }
        /// True when this write created the file. Undo then removes it if it still holds what Pitot wrote.
        public var createdFile: Bool { creation != nil }
    }

    /// What one path held right after Pitot's write. For an element change the path is the
    /// array, so any outside edit to that array counts: the inverse finds its element by index.
    struct Expectation: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case value(raw: [UInt8])
            case absent
            /// A value on the way to the key is not an object, for example when a later
            /// operation of the same group replaced the parent with a string.
            case blocked
        }

        /// The last change the group made at this path.
        let change: JSONEdit.Change
        let state: State

        var path: [String] { change.path }

        init(change: JSONEdit.Change) {
            self.change = change
            state = change.after.map { .value(raw: $0) } ?? .absent
        }

        init(change: JSONEdit.Change, in written: JSONDocument) {
            self.change = change
            switch written.lookup(change.path) {
            case .found(let node): state = .value(raw: written.rawBytes(of: node))
            case .absent: state = .absent
            case .blocked: state = .blocked
            }
        }

        /// Compares decoded values, so reformatting by another tool is not a change.
        func holds(in document: JSONDocument) -> Bool {
            switch (state, document.lookup(path)) {
            case (.absent, .absent), (.blocked, .blocked):
                return true
            case (.value(let raw), .found(let node)):
                do throws(JSONScanError) {
                    return try JSONScanner.scan(raw).value(at: []) == document.decode(node)
                } catch {
                    return false
                }
            default:
                return false
            }
        }
    }

    public enum GroupOutcome: Sendable, Equatable {
        case undone(SettingsGroupWriteResult)
        /// The group created the file and the file still held what Pitot wrote, so it was removed,
        /// with the folders made for it that were empty, deepest first.
        case removedCreatedFile(removedDirectories: [URL])
        /// The group created the file, but the file changed since. It was kept, and only the group's keys were reversed.
        case keptCreatedFile(SettingsGroupWriteResult)
        /// These keys no longer hold what Pitot wrote. Nothing was written;
        /// the group stays so the caller can force it or discard it.
        case changedSince(keys: [[String]])
        /// `force` was asked, but these arrays changed since Pitot wrote them. Their undo finds elements
        /// by position, which may name other elements now, so nothing was written. The group stays; only
        /// discarding it is left.
        case cannotForceArrayChange(keys: [[String]])
        case nothingToUndo
    }

    /// The single-change form of `GroupOutcome`, for callers written before groups.
    public enum Outcome: Sendable, Equatable {
        case undone(SettingsGroupWriteResult)
        case removedCreatedFile(removedDirectories: [URL])
        case keptCreatedFile(SettingsGroupWriteResult)
        /// The first changed key no longer holds the value Pitot wrote. Nothing was
        /// written; the group stays so the caller can force it or discard it.
        case changedSince(JSONEdit.Change)
        case cannotForceArrayChange(keys: [[String]])
        case nothingToUndo
    }

    /// The most groups a log keeps. Each group holds the raw bytes of its changes, so when a new
    /// group would pass the limit, the oldest one is dropped and can no longer be undone.
    public static let historyLimit = 100

    /// Oldest first, at most `historyLimit`.
    public private(set) var entries: [Group] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Records one write as one group. A write with no changes is not recorded.
    public mutating func record(_ result: SettingsGroupWriteResult) {
        var expectations: [Expectation] = []
        for change in result.changes {
            let expectation = Expectation(change: change, in: result.snapshot.document)
            if let index = expectations.firstIndex(where: { Self.isSamePath($0.path, change.path) }) {
                expectations[index] = expectation
            } else {
                expectations.append(expectation)
            }
        }
        append(changes: result.changes, expectations: expectations, creation: result.creation)
    }

    /// Records a single change as a group of one.
    public mutating func record(_ change: JSONEdit.Change) {
        append(changes: [change], expectations: [Expectation(change: change)], creation: nil)
    }

    @discardableResult
    public mutating func discardLast() -> Group? {
        entries.popLast()
    }

    /// Undoes the most recent group as one write: the inverse of each change, in
    /// reverse order. Without `force`, it refuses when any touched key was changed
    /// by someone else since Pitot wrote it. With `force`, it still refuses for an array
    /// that changed since, because element undo finds elements by position.
    ///
    /// A group that created the file removes it instead, but only while the file still holds
    /// exactly the bytes Pitot wrote. A file that changed since is kept and the keys are reversed.
    /// Undo never writes `null` and never creates a file.
    public mutating func undoGroup(in file: SettingsFile, force: Bool = false) throws(SettingsFileError) -> GroupOutcome {
        guard let group = entries.last else { return .nothingToUndo }
        if let removed = try removeCreatedFile(of: group, in: file) { return .removedCreatedFile(removedDirectories: removed) }
        let snapshot = try file.load()
        let changed = group.expectations.filter { !$0.holds(in: snapshot.document) }
        if !force, !changed.isEmpty { return .changedSince(keys: changed.map(\.path)) }
        let arrays = Self.arraysWithElementChanges(among: changed, in: group)
        if !arrays.isEmpty { return .cannotForceArrayChange(keys: arrays) }
        let result = try revert(group, in: file, expectedHash: snapshot.hash)
        return group.createdFile ? .keptCreatedFile(result) : .undone(result)
    }

    /// Same as `undoGroup`, reporting only the first changed key.
    public mutating func undo(in file: SettingsFile, force: Bool = false) throws(SettingsFileError) -> Outcome {
        guard let group = entries.last else { return .nothingToUndo }
        if let removed = try removeCreatedFile(of: group, in: file) { return .removedCreatedFile(removedDirectories: removed) }
        let snapshot = try file.load()
        let changed = group.expectations.filter { !$0.holds(in: snapshot.document) }
        if !force, let first = changed.first { return .changedSince(first.change) }
        let arrays = Self.arraysWithElementChanges(among: changed, in: group)
        if !arrays.isEmpty { return .cannotForceArrayChange(keys: arrays) }
        let result = try revert(group, in: file, expectedHash: snapshot.hash)
        return group.createdFile ? .keptCreatedFile(result) : .undone(result)
    }

    private mutating func append(changes: [JSONEdit.Change], expectations: [Expectation], creation: FileCreation?) {
        guard !changes.isEmpty else { return }
        entries.append(Group(id: UUID(), date: now(), changes: changes, expectations: expectations, creation: creation))
        if entries.count > Self.historyLimit { entries.removeFirst(entries.count - Self.historyLimit) }
    }

    /// Nil when the group created no file, or the file changed since and stays.
    private mutating func removeCreatedFile(of group: Group, in file: SettingsFile) throws(SettingsFileError) -> [URL]? {
        guard let creation = group.creation, let removed = try file.removeCreatedFile(creation) else { return nil }
        entries.removeLast()
        return removed
    }

    private mutating func revert(_ group: Group, in file: SettingsFile, expectedHash: String) throws(SettingsFileError) -> SettingsGroupWriteResult {
        let inverse = group.changes.reversed().map(\.inverse)
        let result = try file.apply(operations: inverse, expectedHash: expectedHash, allowingCreation: false)
        entries.removeLast()
        return result
    }

    /// The changed paths where the group edited array elements, whose inverses find elements by position.
    private static func arraysWithElementChanges(among changed: [Expectation], in group: Group) -> [[String]] {
        changed.map(\.path).filter { path in group.changes.contains { $0.element != nil && isSamePath($0.path, path) } }
    }

    /// Keys compare as UTF-16 code units, like JavaScript, so `"é"` and `"e\u{301}"` stay different keys.
    private static func isSamePath(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
    }
}
