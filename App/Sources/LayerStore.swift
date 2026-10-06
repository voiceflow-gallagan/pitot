import PitotCore
import CryptoKit
import Foundation
import Observation

extension LayerID {
    var displayName: String {
        switch self {
        case .user: "User"
        case .project: "Project"
        case .local: "Project-local"
        case .managed: "Organization"
        }
    }
}

extension SettingsLayerKind {
    var displayName: String { LayerID(self).displayName }
}

/// What one read of a layer file found.
struct LayerRead: Sendable {
    let snapshot: SettingsSnapshot?
    let layer: SettingsLayer
}

/// One settings file Pitot can write, with its snapshot, watcher and undo history.
///
/// Files are read and scanned off the main actor. Each read carries a generation number, and a
/// result older than the newest read or write is dropped, so a slow read never replaces newer content.
@MainActor
@Observable
final class LayerStore {
    let kind: SettingsLayerKind
    /// The project folder for project and local layers. Nil for the user layer.
    let project: URL?
    let url: URL
    let file: SettingsFile

    private(set) var snapshot: SettingsSnapshot?
    /// The file as Claude Code reads it: loaded, missing, invalid or unreadable.
    private(set) var layer: SettingsLayer
    private(set) var undoLog = UndoLog()
    /// The keys each group asked to change, such as `env.NAME`. Core records the outermost key that
    /// changed, which is `env` when that write created the env block.
    private(set) var historyKeys: [UndoLog.Group.ID: [String]] = [:]
    /// False until the first read finishes, so a file that exists is never shown as missing.
    private(set) var hasLoaded = false
    private var lastWrittenHash: String?
    private var generation = 0
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private var isStartingWatcher = false
    private let reader: Reader

    typealias Reader = @Sendable (SettingsFile, LayerID, URL) -> LayerRead

    init(kind: SettingsLayerKind, project: URL?, url: URL, backupRoot: URL, reader: @escaping Reader = LayerStore.read) {
        self.reader = reader
        self.kind = kind
        self.project = project
        self.url = url
        // A project file is read and written only while it stays inside the project, links followed.
        file = SettingsFile(
            url: url, backupRoot: backupRoot, emptyFilePolicy: .treatAsEmptyObject,
            missingFilePolicy: project.map { .create(root: $0) } ?? .error, confinedTo: project)
        layer = SettingsLayer(id: LayerID(kind), url: url, state: .missing)
    }

    /// The stores for a project's shared and local files. Backups go to a folder per project, so
    /// pruning one file's backups never removes another file's.
    static func pair(for folder: URL, backupRoot: URL) -> (project: LayerStore, local: LayerStore) {
        let claude = folder.appendingPathComponent(".claude", isDirectory: true)
        let digest = SHA256.hash(data: Data(folder.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let backups = backupRoot.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("\(folder.lastPathComponent)-\(digest)", isDirectory: true)
        return (
            LayerStore(kind: .project, project: folder, url: claude.appendingPathComponent("settings.json"), backupRoot: backups),
            LayerStore(kind: .local, project: folder, url: claude.appendingPathComponent("settings.local.json"), backupRoot: backups)
        )
    }

    var id: LayerID { LayerID(kind) }
    var isMissing: Bool { layer.state == .missing }
    var canUndo: Bool { !undoLog.entries.isEmpty }

    /// "Project-local · pitot", or "User".
    var title: String {
        project.map { "\(kind.displayName) · \($0.lastPathComponent)" } ?? kind.displayName
    }

    /// Why Claude Code skips this file, or nil. Pitot does not edit a file until it is fixed.
    var problem: String? {
        switch layer.state {
        case .invalid(let problem): "Claude Code ignores \(url.path): \(problem). Fix the file to edit it here."
        case .unreadable(let reason): "Pitot cannot read \(url.path): \(reason)"
        case .loaded, .missing: nil
        }
    }

    /// The file edits are computed against. A missing project file counts as `{}`, which Pitot creates.
    var editDocument: JSONDocument? {
        guard problem == nil else { return nil }
        if let snapshot { return snapshot.document }
        return isMissing && project != nil ? Self.emptyDocument : nil
    }

    var editBytes: [UInt8] { snapshot?.bytes ?? Self.emptyBytes }
    var expectedHash: String { snapshot?.hash ?? SettingsFile.missingFileHash }
    var isEditable: Bool { hasLoaded && editDocument != nil }

    /// Reads the file again off the main actor. True when it changed and the change was not
    /// Pitot's own write. False, with nothing changed, when a newer read or write came first.
    @discardableResult
    func reload() async -> Bool {
        generation += 1
        let current = generation
        let (reader, file, id, url) = (reader, file, id, url)
        let read = await Task.detached { reader(file, id, url) }.value
        guard current == generation else { return false }
        let previous = snapshot?.hash
        snapshot = read.snapshot
        layer = read.layer
        let loadedBefore = hasLoaded
        hasLoaded = true
        return loadedBefore && read.snapshot?.hash != previous && read.snapshot?.hash != lastWrittenHash
    }

    /// Reads and scans `url`. It runs off the main actor and touches no store state.
    nonisolated static func read(_ file: SettingsFile, id: LayerID, url: URL) -> LayerRead {
        switch Result(catching: { () throws(SettingsFileError) in try file.load() }) {
        case .success(let loaded):
            return LayerRead(snapshot: loaded, layer: LayerLoader.layer(id: id, url: url, bytes: loaded.bytes))
        case .failure(.missingFile):
            return LayerRead(snapshot: nil, layer: SettingsLayer(id: id, url: url, state: .missing))
        case .failure(.invalidJSON(let reason)):
            return LayerRead(snapshot: nil, layer: SettingsLayer(id: id, url: url, state: .invalid(.syntax(reason))))
        case .failure(let error):
            // Nothing is read again here: a file outside the project or over the size limit stays unread.
            return LayerRead(snapshot: nil, layer: SettingsLayer(id: id, url: url, state: .unreadable(ErrorText.describe(error))))
        }
    }

    /// Records a write as one undo group, labeled with the keys `operations` asked for.
    func record(_ result: SettingsGroupWriteResult, operations: [JSONEdit.Operation]) {
        undoLog.record(result)
        if let group = undoLog.entries.last, !result.changes.isEmpty {
            var seen: Set<String> = []
            historyKeys[group.id] = operations.map { $0.path.joined(separator: ".") }.filter { seen.insert($0).inserted }
        }
        accept(result.snapshot)
    }

    /// Takes the content Pitot just wrote. A read that started before the write is dropped.
    func accept(_ written: SettingsSnapshot) {
        generation += 1
        hasLoaded = true
        snapshot = written
        layer = LayerLoader.layer(id: id, url: url, bytes: written.bytes)
        lastWrittenHash = written.hash
    }

    func replaceUndoLog(_ log: UndoLog) {
        undoLog = log
        let remaining = Set(log.entries.map(\.id))
        historyKeys = historyKeys.filter { remaining.contains($0.key) }
    }

    func historyLabel(for group: UndoLog.Group) -> [String] {
        historyKeys[group.id] ?? group.keys.map { $0.joined(separator: ".") }
    }

    /// Starts watching when the file's folder exists. A project without `.claude` has none yet, so
    /// this is called again after every reload and write. The watcher is set up off the main actor,
    /// because it reads the folder.
    func startWatching(_ onChange: @escaping @MainActor () async -> Void) {
        guard watcher == nil, !isStartingWatcher else { return }
        isStartingWatcher = true
        let url = url
        watchTask = Task { [weak self] in
            let made = await Task.detached { try? FileWatcher(url: url) }.value
            guard let made, let changes = self?.adopt(made) else {
                made?.stop()
                self?.isStartingWatcher = false
                return
            }
            // A change made while the watcher was being set up has no event, so check once now.
            await onChange()
            for await _ in changes {
                await onChange()
            }
        }
    }

    /// Nil when `stopWatching()` ran while the watcher was being set up.
    private func adopt(_ made: FileWatcher) -> AsyncStream<FileChange>? {
        guard isStartingWatcher else { return nil }
        isStartingWatcher = false
        watcher = made
        return made.changes
    }

    /// Stops the watcher and drops any read still in flight.
    func stopWatching() {
        generation += 1
        isStartingWatcher = false
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    private static let emptyBytes: [UInt8] = Array("{}\n".utf8)
    private static let emptyDocument = LayerLoader.layer(id: .user, url: nil, bytes: emptyBytes).document
}
