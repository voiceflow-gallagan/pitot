import PitotCore
import Foundation

extension SettingsModel {
    /// Adds, replaces or drops the pending change for `tweak` in the selected layer.
    ///
    /// A locked row, a row the layer cannot hold, and a file Claude Code skips take no change. A row
    /// disabled by a dependency or a version takes only a reset. A value the layer cannot hold is
    /// refused with its reason in `refusals`. A change the catalog wants confirmed waits in
    /// `confirmRequest` until `confirmChange()`.
    func requestChange(_ value: TweakValue?, for tweak: Tweak) {
        guard !isWriting, let document = selectedStore?.editDocument else { return }
        let state = row(tweak)
        if state.isLocked || state.rowRefusal != nil { return }
        if value != nil, state.disabledReason != nil { return }
        if case .refused(let reason) = tweak.canWrite(in: scope, value: value) {
            refusals[tweak.id] = reason
            refresh()
            return
        }
        refusals[tweak.id] = nil
        if let current = pending[tweak.id], current.value == value {
            refresh()
            return
        }
        if tweak.operation(for: value, in: document) == nil {
            pending[tweak.id] = nil
            refresh()
            return
        }
        if needsConfirm(tweak, to: value), let confirm = tweak.confirm {
            confirmRequest = .change(tweak, value: value, message: confirm.message)
            refresh()
            return
        }
        pending[tweak.id] = ProposedChange(tweakId: tweak.id, value: value)
        refresh()
    }

    /// Whether moving from the value in effect across all layers to `value` needs the catalog's confirmation.
    func needsConfirm(_ tweak: Tweak, to value: TweakValue?) -> Bool {
        Tweak.Confirmation.isRequired(for: tweak, old: tweak.reading(in: effective), new: value)
    }

    func confirmChange() async {
        guard let request = confirmRequest else { return }
        confirmRequest = nil
        switch request.action {
        case .change(let tweakId, let value):
            guard !isWriting else { return }
            pending[tweakId] = ProposedChange(tweakId: tweakId, value: value)
            refresh()
        case .writeSharedProject:
            await writePending()
        }
    }

    func cancelConfirm() {
        confirmRequest = nil
    }

    func discardPending() {
        pending = [:]
        refusals = [:]
        refresh()
    }

    /// Writes every pending change and its auto-sets to the selected layer in one write, recorded as
    /// one undo group. The shared project file asks first, because it is usually committed.
    func applyPending() async {
        guard !isWriting, review.canApply, let store = selectedStore else { return }
        if store.kind == .project {
            confirmRequest = .sharedProjectWrite(store.url)
            return
        }
        await writePending()
    }

    private func writePending() async {
        guard review.canApply, let store = selectedStore else { return }
        if await write(review.operations, to: store, expectedHash: store.expectedHash) {
            pending = [:]
            refresh()
        }
    }

    /// Writes `operations` to `store` as one group: one write, at most one backup, one undo entry.
    /// False after an error, which is shown in `errorMessage`.
    @discardableResult
    func write(_ operations: [JSONEdit.Operation], to store: LayerStore, expectedHash: String) async -> Bool {
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        rebasedNotice = false
        let file = store.file
        store.beginWrite()
        let outcome = await Self.run { () throws(SettingsFileError) in
            try file.apply(operations: operations, expectedHash: expectedHash)
        }
        store.endWrite()
        switch outcome {
        case .success(let result):
            store.record(result, operations: operations)
            rebasedNotice = result.rebased
            rebuildEffective()
            reconcilePending()
            startWatching()
            if result.createdFile, store.kind == .local { await checkGitIgnore() }
            return true
        case .failure(let error):
            errorMessage = ErrorText.describe(error, operations: operations)
            await reload()
            return false
        }
    }

    // MARK: Undo

    /// Undoes the newest group of the selected layer. Without `force` it stops when another program
    /// changed one of its keys. The other layers are not touched.
    func undo(force: Bool = false) async {
        guard !isWriting, let store = selectedStore, store.canUndo else { return }
        isWriting = true
        defer { isWriting = false }
        blockedUndo = nil
        let file = store.file
        let log = store.undoLog
        store.beginWrite()
        let outcome = await Self.run { () throws(SettingsFileError) in
            var copy = log
            let result = try copy.undoGroup(in: file, force: force)
            return (result, copy)
        }
        store.endWrite()
        switch outcome {
        case .success(let (result, updatedLog)):
            store.replaceUndoLog(updatedLog)
            switch result {
            case .undone(let written), .keptCreatedFile(let written):
                store.accept(written.snapshot)
            case .removedCreatedFile:
                store.stopWatching()
                await store.reload()
            case .changedSince(let keys):
                blockedUndo = keys
            case .cannotForceArrayChange(let keys):
                errorMessage = ErrorText.cannotForce(keys)
            case .nothingToUndo:
                break
            }
            rebuildEffective()
            reconcilePending()
        case .failure(let error):
            errorMessage = ErrorText.describe(error)
            await reload()
        }
    }

    func dismissBlockedUndo() {
        blockedUndo = nil
    }
}
