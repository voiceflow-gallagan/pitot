import PitotCore
import Foundation
import Observation

/// One context in the list: every block of the file with that context, merged in file order.
struct KeybindingGroup: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        let key: String
        let action: String?
        let issues: [KeybindingsValidator.Issue]
        let isLegacy: Bool
        let replacedBy: String?
        let description: String?
        let defaultKey: String?
        let isPending: Bool

        var id: String { key }
    }

    let context: String
    let description: String?
    let rows: [Row]

    var id: String { context }
}

/// What Apply would write: the pending edits run in order over the file, as one list of operations.
struct KeybindingsPreview: Equatable {
    var operations: [JSONEdit.Operation] = []
    var notes: [String] = []
    var warnings: [String] = []
    /// Edits that no longer apply, for example because the file changed. Any problem blocks Apply.
    var problems: [String] = []
    var diff: [DiffLine] = []
    var createsFile = false
    /// The file as it would read after Apply.
    var file: KeybindingsFile?

    var canApply: Bool { !operations.isEmpty && problems.isEmpty }
}

/// The user's `keybindings.json`: its own file, watcher, pending edits and undo history.
/// The settings scope picker does not apply here.
@MainActor
@Observable
final class KeybindingsModel {
    static let reloadNote = "Claude Code reads this file again by itself. You do not need to restart it."

    let catalog: KeybindingsCatalog
    let url: URL
    let file: SettingsFile

    private(set) var snapshot: SettingsSnapshot? {
        didSet { bindingCount = Self.countBindings(in: snapshot) }
    }
    /// The bindings in the file on disk, pending edits not included. Shown on the sidebar tile.
    private(set) var bindingCount = 0
    private(set) var isMissing = true
    /// Why the file cannot be edited: invalid JSON or a shape Claude Code does not read.
    private(set) var problem: String?
    private(set) var undoLog = UndoLog()
    private(set) var pending: [KeybindingEdit] = []
    private(set) var preview = KeybindingsPreview()
    private(set) var isWriting = false
    private(set) var blockedUndo: [[String]]?
    /// The edit summaries of each applied group, for the history list.
    private(set) var historyKeys: [UndoLog.Group.ID: [String]] = [:]
    var externalChangeBanner = false
    var errorMessage: String?

    /// The file as it would read after the pending edits, nil while it would still be missing.
    private var previewDocument: JSONDocument?
    private var lastWrittenHash: String?
    private var generation = 0
    private var writesInFlight = 0
    /// False until the first read finishes, so an existing file is never shown as missing.
    private(set) var hasLoaded = false
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?
    private var isStartingWatcher = false

    /// What one read of the file found. Reads run off the main actor.
    private struct Read: Sendable {
        let snapshot: SettingsSnapshot?
        let isMissing: Bool
        let problem: String?
    }

    /// A missing file is created only inside `url`'s folder, with the docs header and an empty list.
    init(catalog: KeybindingsCatalog, url: URL, backupRoot: URL) {
        self.catalog = catalog
        self.url = url
        var initial: [UInt8]?
        do throws(KeybindingsFileError) {
            initial = try KeybindingsEditor.initialContent(catalog: catalog)
            headerProblem = nil
        } catch {
            initial = nil
            headerProblem = "Pitot cannot create \(url.lastPathComponent): \(ErrorText.describe(error))."
        }
        initialContent = initial ?? Array("{}\n".utf8)
        file = SettingsFile(
            url: url, backupRoot: backupRoot, emptyFilePolicy: .treatAsEmptyObject,
            missingFilePolicy: .create(root: url.deletingLastPathComponent(), initialContent: initialContent),
            nullValuePolicy: .allow)
    }

    /// The docs header and an empty list, the content of a file Pitot creates.
    private let initialContent: [UInt8]
    /// Set when the catalog header does not make valid JSON. A missing file then cannot be created.
    let headerProblem: String?

    var canEdit: Bool { hasLoaded && problem == nil && !isWriting && !(isMissing && headerProblem != nil) }
    var canUndo: Bool { !undoLog.entries.isEmpty }
    var hasPending: Bool { !pending.isEmpty }

    // MARK: Reading

    /// Reads the file again off the main actor. True when it changed and the change was not Pitot's
    /// own write. A read that a newer read or write overtakes publishes nothing.
    @discardableResult
    func reload() async -> Bool {
        generation += 1
        let current = generation
        let (file, url) = (file, url)
        let read = await Task.detached { Self.read(file, url: url) }.value
        guard current == generation, writesInFlight == 0 else { return false }
        let previous = snapshot?.hash
        snapshot = read.snapshot
        isMissing = read.isMissing
        problem = read.problem
        rebuildPreview()
        let loadedBefore = hasLoaded
        hasLoaded = true
        return loadedBefore && snapshot?.hash != previous && snapshot?.hash != lastWrittenHash
    }

    private static func countBindings(in snapshot: SettingsSnapshot?) -> Int {
        guard let document = snapshot?.document, let file = try? KeybindingsFile(document: document) else { return 0 }
        return file.blocks.reduce(0) { $0 + $1.bindings.count }
    }

    private nonisolated static func read(_ file: SettingsFile, url: URL) -> Read {
        switch Result(catching: { () throws(SettingsFileError) in try file.load() }) {
        case .success(let loaded):
            do throws(KeybindingsFileError) {
                _ = try KeybindingsFile(document: loaded.document)
                return Read(snapshot: loaded, isMissing: false, problem: nil)
            } catch {
                return Read(
                    snapshot: loaded, isMissing: false,
                    problem: "Claude Code cannot read \(url.path): \(ErrorText.describe(error)). Fix the file to edit it here.")
            }
        case .failure(.missingFile):
            return Read(snapshot: nil, isMissing: true, problem: nil)
        case .failure(let error):
            return Read(snapshot: nil, isMissing: false, problem: "Pitot cannot edit \(url.path): \(ErrorText.describe(error))")
        }
    }

    /// The list by context, in the order contexts first appear, as the file would read after Apply.
    func groups(search: String = "") -> [KeybindingGroup] {
        guard problem == nil, let editor = makeEditor(previewDocument) else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let touched = Set(pending.map { "\($0.context)|\(normalized($0.key))" })
        var order: [String] = []
        var rows: [String: [KeybindingGroup.Row]] = [:]
        for block in editor.summary() {
            if rows[block.context] == nil { order.append(block.context) }
            for row in block.rows {
                let entry = row.action.flatMap(catalog.action(id:))
                let item = KeybindingGroup.Row(
                    key: row.key, action: row.action, issues: row.issues, isLegacy: row.isLegacyAction, replacedBy: entry?.replacedBy,
                    description: row.description, defaultKey: row.defaultKey, isPending: touched.contains("\(block.context)|\(normalized(row.key))"))
                guard query.isEmpty || [block.context, row.key, row.action ?? "null", row.description ?? ""].contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                }) else { continue }
                rows[block.context, default: []].append(item)
            }
        }
        return order.compactMap { context in
            guard let items = rows[context], !(items.isEmpty && !query.isEmpty) else { return nil }
            return KeybindingGroup(context: context, description: catalog.context(named: context)?.description, rows: items)
        }
    }

    /// Actions a picker offers for `context`: the actions documented there, the replacements of its
    /// legacy actions, and the actions the docs name no context for. Legacy names are never offered.
    func actions(for context: String) -> [KeybindingsCatalog.Action] {
        let replacements = Set(catalog.actions.filter { $0.legacy && $0.contexts.contains(context) }.compactMap(\.replacedBy))
        let offered = catalog.actions.filter { !$0.legacy }
        return offered.filter { $0.contexts.contains(context) }
            + offered.filter { !$0.contexts.contains(context) && replacements.contains($0.id) }
            + offered.filter { $0.contexts.isEmpty }
    }

    // MARK: Editing

    /// The plan `edit` would get after the pending edits, for live validation. Nothing is queued.
    func check(_ edit: KeybindingEdit) -> KeybindingsEditor.Plan? {
        guard problem == nil else { return nil }
        return makeEditor(previewDocument).map(edit.plan(with:))
    }

    /// Queues `edit` when the editor accepts it, and returns the issues either way.
    @discardableResult
    func request(_ edit: KeybindingEdit) -> [KeybindingsValidator.Issue] {
        guard canEdit, let plan = check(edit) else { return [] }
        guard !plan.isRefused else { return plan.blockingIssues.isEmpty ? plan.issues : plan.blockingIssues }
        pending.append(edit)
        rebuildPreview()
        return plan.issues
    }

    func discardPending() {
        pending = []
        rebuildPreview()
    }

    /// Writes every pending edit in one write and records one undo group.
    func apply() async {
        guard !isWriting, preview.canApply else { return }
        let operations = preview.operations
        let labels = pending.map(\.summary)
        let expectedHash = snapshot?.hash ?? SettingsFile.missingFileHash
        isWriting = true
        defer { isWriting = false }
        let file = file
        beginWrite()
        let outcome = await SettingsModel.run { () throws(SettingsFileError) in
            try file.apply(operations: operations, expectedHash: expectedHash)
        }
        endWrite()
        switch outcome {
        case .success(let result):
            undoLog.record(result)
            if let group = undoLog.entries.last { historyKeys[group.id] = labels }
            accept(result.snapshot)
            pending = []
            rebuildPreview()
        case .failure(let error):
            errorMessage = ErrorText.describe(error, operations: operations)
            await reload()
        }
    }

    func undo(force: Bool = false) async {
        guard !isWriting, canUndo else { return }
        isWriting = true
        defer { isWriting = false }
        blockedUndo = nil
        let file = file
        let log = undoLog
        beginWrite()
        let outcome = await SettingsModel.run { () throws(SettingsFileError) in
            var copy = log
            let result = try copy.undoGroup(in: file, force: force)
            return (result, copy)
        }
        endWrite()
        switch outcome {
        case .success(let (result, updatedLog)):
            undoLog = updatedLog
            let remaining = Set(updatedLog.entries.map(\.id))
            historyKeys = historyKeys.filter { remaining.contains($0.key) }
            switch result {
            case .undone(let written), .keptCreatedFile(let written):
                accept(written.snapshot)
            case .removedCreatedFile:
                await reload()
            case .changedSince(let keys):
                blockedUndo = keys
            case .cannotForceArrayChange(let keys):
                errorMessage = ErrorText.cannotForce(keys)
            case .nothingToUndo:
                break
            }
            rebuildPreview()
        case .failure(let error):
            errorMessage = ErrorText.describe(error)
            await reload()
        }
    }

    func dismissBlockedUndo() {
        blockedUndo = nil
    }

    var history: [HistoryEntry] {
        undoLog.entries.map { group in
            HistoryEntry(
                id: group.id, date: group.date, layer: "Keybindings", keys: historyKeys[group.id] ?? group.keys.map { $0.joined(separator: ".") },
                isNewestInLayer: group.id == undoLog.entries.last?.id, kind: nil)
        }
    }

    // MARK: Watching

    /// Sets up the watcher off the main actor, because it reads the folder.
    func startWatching() {
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
            // A change made while the watcher was being set up has no event, so read once now.
            if await self?.reload() == true { self?.externalChangeBanner = true }
            for await _ in changes {
                if await self?.reload() == true { self?.externalChangeBanner = true }
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

    // MARK: Private

    /// The watcher can report Pitot's own write before the write's result is taken. A read in that
    /// window is dropped, so the write never looks like an outside edit. `endWrite` and taking the
    /// result run in one main-actor step, so no read lands between them.
    private func beginWrite() {
        writesInFlight += 1
        generation += 1
    }

    private func endWrite() {
        writesInFlight = max(0, writesInFlight - 1)
    }

    /// Takes the content Pitot just wrote. A read that started before the write is dropped.
    private func accept(_ written: SettingsSnapshot) {
        generation += 1
        hasLoaded = true
        snapshot = written
        isMissing = false
        problem = nil
        lastWrittenHash = written.hash
    }

    /// Nil for a file whose shape Claude Code cannot read; `reload()` reports that as `problem`.
    private func makeEditor(_ document: JSONDocument?) -> KeybindingsEditor? {
        do throws(KeybindingsFileError) {
            return try KeybindingsEditor(catalog: catalog, document: document)
        } catch {
            return nil
        }
    }

    private func rebuildPreview() {
        var result = KeybindingsPreview()
        var document = snapshot?.document
        let original = snapshot?.bytes ?? []
        var bytes = snapshot?.bytes ?? initialContent
        for edit in pending {
            guard let editor = makeEditor(document) else { break }
            let plan = edit.plan(with: editor)
            if plan.isRefused {
                let reason = (plan.blockingIssues.first ?? plan.issues.first)?.message ?? "It no longer applies to the file."
                result.problems.append("\(edit.summary): \(reason)")
                continue
            }
            switch Self.applying(plan.operations, to: bytes) {
            case .success(let next):
                bytes = next.bytes
                document = next.document
                result.operations += plan.operations
                result.notes += plan.notes
                result.warnings += plan.issues.map { "\(edit.key): \($0.message)" }
                result.createsFile = result.createsFile || plan.createsFile
            case .failure(let error):
                result.problems.append("\(edit.summary): \(ErrorText.describe(error)).")
            }
        }
        previewDocument = document
        if problem == nil, let editor = makeEditor(document) {
            result.file = editor.file
        }
        if !result.operations.isEmpty {
            result.diff = LineDiff.unified(old: original, new: bytes)
        }
        preview = result
    }

    private static func applying(_ operations: [JSONEdit.Operation], to bytes: [UInt8]) -> Result<(bytes: [UInt8], document: JSONDocument), JSONEditError> {
        var current = bytes
        for operation in operations {
            do throws(JSONEditError) {
                current = try JSONEdit.apply(operation, to: current).bytes
            } catch {
                return .failure(error)
            }
        }
        do throws(JSONScanError) {
            return .success((current, try JSONScanner.scan(current)))
        } catch {
            return .failure(.producedInvalidJSON(error))
        }
    }

    private func normalized(_ key: String) -> String {
        KeyString(key, syntax: catalog.keySyntax)?.normalized ?? key.lowercased()
    }
}
