import PitotCore
import Foundation

/// One applied group in the history list, from any layer.
struct HistoryEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// "User", or the layer and project, such as "Project-local · pitot".
    let layer: String
    let keys: [String]
    /// The newest group of its layer, the one undo would reverse there.
    let isNewestInLayer: Bool
    /// Nil for the keybindings file.
    let kind: SettingsLayerKind?
}

extension SettingsModel {
    /// The groups of every open layer and of the keybindings file, newest first.
    var history: [HistoryEntry] {
        (keybindings.history + stores.flatMap { store in
            store.undoLog.entries.map { group in
                HistoryEntry(
                    id: group.id, date: group.date, layer: store.title, keys: store.historyLabel(for: group),
                    isNewestInLayer: group.id == store.undoLog.entries.last?.id, kind: store.kind)
            }
        })
        .sorted { $0.date > $1.date }
    }

    /// Opens `folder` as the project and selects its local file, the personal one.
    func selectProject(_ folder: URL) async {
        let folder = folder.standardizedFileURL
        guard folder != projectFolder else { return }
        projectStores?.project.stopWatching()
        projectStores?.local.stopWatching()
        let pair = projectCache[folder.path] ?? LayerStore.pair(for: folder, backupRoot: backupRoot)
        cache(pair, for: folder.path)
        projectFolder = folder
        projectStores = pair
        pendingByScope[.project] = nil
        pendingByScope[.local] = nil
        localNotIgnored = false
        services.recentProjects.remember(folder)
        selectScope(.local)
        rebuildEffective()
        await pair.project.reload()
        await pair.local.reload()
        guard projectFolder == folder else { return }
        rebuildEffective()
        reconcilePending()
        startWatching()
        await refreshProjectChoices()
        await checkGitIgnore()
    }

    /// Keeps `pair` as the newest entry and drops the oldest projects beyond the limit, with their history.
    private func cache(_ pair: (project: LayerStore, local: LayerStore), for path: String) {
        projectCache[path] = pair
        projectCacheOrder.removeAll { $0 == path }
        projectCacheOrder.append(path)
        while projectCacheOrder.count > Self.projectCacheLimit {
            let oldest = projectCacheOrder.removeFirst()
            projectCache[oldest]?.project.stopWatching()
            projectCache[oldest]?.local.stopWatching()
            projectCache[oldest] = nil
        }
    }

    func closeProject() {
        projectStores?.project.stopWatching()
        projectStores?.local.stopWatching()
        projectStores = nil
        projectFolder = nil
        pendingByScope[.project] = nil
        pendingByScope[.local] = nil
        localNotIgnored = false
        selectScope(.user)
        rebuildEffective()
        refresh()
    }

    /// False when the scope needs a project and none is open.
    @discardableResult
    func selectScope(_ kind: SettingsLayerKind) -> Bool {
        guard kind == .user || projectStores != nil else { return false }
        if kind != scope {
            scope = kind
            blockedUndo = nil
            refusals = [:]
        }
        refresh()
        return true
    }

    /// Selects the layer that keeps a row's value out of effect, when Pitot can write it.
    func switchScope(to layer: LayerID) {
        guard let kind = layer.writableKind else { return }
        selectScope(kind)
    }

    /// Sets `localNotIgnored` when the project's local file would be committed. No git, or a folder
    /// outside a repository, gives no warning.
    func checkGitIgnore() async {
        guard let folder = projectFolder else {
            localNotIgnored = false
            return
        }
        let ignored = await services.gitCheck.isIgnored(".claude/settings.local.json", in: folder)
        guard folder == projectFolder else { return }
        localNotIgnored = ignored == false
    }

    func loadProjectSuggestions() async {
        let source = services.projectSuggestions
        projectSuggestionPaths = await Task.detached { source.projectPaths() }.value
        await refreshProjectChoices()
    }

    /// Rebuilds the project menu. Checking that each folder still exists touches the disk, so it runs
    /// off the main actor.
    func refreshProjectChoices() async {
        let recent = services.recentProjects.paths
        let suggestions = projectSuggestionPaths
        projectChoices = await Task.detached { ProjectChoices.make(recent: recent, suggestions: suggestions) }.value
    }
}
