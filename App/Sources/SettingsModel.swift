import PitotCore
import Foundation
import Observation

/// What the layer stack needs from outside, so tests can replace it.
struct LayerServices {
    var managedFolder: URL
    var recentProjects: RecentProjectStore
    var projectSuggestions: ProjectSuggestionSource
    var gitCheck: GitIgnoreCheck
}

/// What the sidebar shows: a settings category, the keybindings editor or the unverified keys.
enum SidebarItem: Hashable {
    case category(String)
    case keybindings
    case unverified

    /// A name to remember the section by between launches.
    var id: String {
        switch self {
        case .category(let name): "category:\(name)"
        case .keybindings: "keybindings"
        case .unverified: "unverified"
        }
    }

    init?(id: String) {
        switch id {
        case "keybindings": self = .keybindings
        case "unverified": self = .unverified
        case let id where id.hasPrefix("category:"): self = .category(String(id.dropFirst("category:".count)))
        default: return nil
        }
    }
}

struct GoToShortcut: Equatable {
    let item: SidebarItem
    let key: Character
}

/// The settings layers Pitot shows: the user file, a chosen project's shared and local files, and
/// the managed settings it only reads. Edits go to the layer the scope picker selects.
///
/// State that the extensions in other files change has an internal setter; views only read it.
@MainActor
@Observable
final class SettingsModel {
    let settingsURL: URL
    let mode: FileMode
    let catalog: Catalog
    /// Category names in the order they first appear in the catalog.
    let categories: [String]
    let user: LayerStore
    /// The user's keybindings file. The scope picker does not apply to it.
    let keybindings: KeybindingsModel
    let unverified: UnverifiedCatalog

    var projectFolder: URL? {
        didSet { session?.projectPath = projectFolder?.path }
    }
    var projectStores: (project: LayerStore, local: LayerStore)?
    var managed: SettingsLayer
    /// All layers merged, rebuilt after every reload and write.
    var effective: EffectiveSettings
    var scope: SettingsLayerKind = .user {
        didSet { session?.scope = scope.rawValue }
    }
    var claude: ClaudeStatus = .checking
    var isWriting = false
    /// One change per tweak id for each layer. A nil value removes the key from that layer.
    var pendingByScope: [SettingsLayerKind: [String: ProposedChange]] = [:]
    var rows: [String: RowState] = [:]
    var review = ReviewPlan()
    var rebasedNotice = false
    /// Keys another program changed since Pitot wrote the group it tried to undo.
    var blockedUndo: [[String]]?
    /// Values the selected layer cannot hold that the user tried to pick, with the reason.
    var refusals: [String: String] = [:]
    /// True when git does not ignore the project's local settings file.
    var localNotIgnored = false
    var projectSuggestionPaths: [String] = []
    /// The project menu: recent folders, then Claude Code's projects, all still on disk.
    var projectChoices: [ProjectChoice] = []
    /// Project stores by folder path, so a project's undo history survives switching projects.
    /// It keeps the `projectCacheLimit` most recently opened projects.
    var projectCache: [String: (project: LayerStore, local: LayerStore)] = [:]
    /// Folder paths in `projectCache`, oldest first.
    var projectCacheOrder: [String] = []
    static let projectCacheLimit = 50

    var confirmRequest: ConfirmRequest?
    /// The setup questions sheet, while it is open.
    var onboarding: OnboardingModel?
    var searchText = ""
    /// The sidebar's selection. Picking a category also makes it the settings category shown.
    var sidebarSelection: SidebarItem? {
        didSet {
            if case .category(let category)? = sidebarSelection { selectedCategory = category }
            if let sidebarSelection { session?.section = sidebarSelection.id }
        }
    }
    var selectedCategory: String?
    var externalChangeBanner = false
    var errorMessage: String?

    /// Nil with `setupQuestionsError` set when the bundled questions failed to load.
    let setupQuestions: OnboardingFile?
    let setupQuestionsError: String?
    /// Nil when the questions must not open by themselves, such as for a custom settings path.
    let launchFlags: OnboardingFlagStore?
    /// Nil when the selection must not be remembered, such as for a custom settings path.
    let session: SessionStore?
    let services: LayerServices
    let backupRoot: URL

    private let probe: ClaudeProbe
    private let managedReader: ManagedSettingsReader
    private var managedWatcher: FileWatcher?
    private var managedTask: Task<Void, Never>?
    private var isStartingManagedWatcher = false
    private var reloadGeneration = 0

    init(
        catalog: Catalog,
        keybindingsCatalog: KeybindingsCatalog,
        unverified: UnverifiedCatalog,
        configuration: LaunchConfiguration,
        setupQuestions: Result<OnboardingFile, CatalogLoadFailure> = .failure(.missing("onboarding.json")),
        launchFlags: OnboardingFlagStore? = nil,
        services: LayerServices,
        session: SessionStore? = nil,
        probe: ClaudeProbe = ClaudeProbe()
    ) {
        self.catalog = catalog
        self.session = session
        var seen: Set<String> = []
        categories = catalog.tweaks.map(\.category).filter { seen.insert($0).inserted }
        selectedCategory = categories.first
        sidebarSelection = categories.first.map(SidebarItem.category) ?? .keybindings
        self.unverified = unverified
        keybindings = KeybindingsModel(
            catalog: keybindingsCatalog, url: configuration.keybindingsURL,
            backupRoot: configuration.backupRoot.appendingPathComponent("Keybindings", isDirectory: true))
        switch setupQuestions {
        case .success(let file):
            self.setupQuestions = file
            setupQuestionsError = nil
        case .failure(let failure):
            self.setupQuestions = nil
            setupQuestionsError = failure.message
        }
        self.launchFlags = launchFlags
        self.services = services
        settingsURL = configuration.settingsURL
        mode = configuration.mode
        backupRoot = configuration.backupRoot
        user = LayerStore(kind: .user, project: nil, url: configuration.settingsURL, backupRoot: configuration.backupRoot)
        managedReader = ManagedSettingsReader(folder: services.managedFolder)
        managed = SettingsLayer(id: .managed, url: services.managedFolder, state: .missing)
        effective = EffectiveSettings(layers: [])
        self.probe = probe
        errorMessage = configuration.setupError
    }

    var selectedStore: LayerStore? {
        store(for: scope)
    }

    func store(for kind: SettingsLayerKind) -> LayerStore? {
        switch kind {
        case .user: user
        case .project: projectStores?.project
        case .local: projectStores?.local
        }
    }

    /// Every store this session has opened: the user file first, then each project's files.
    var stores: [LayerStore] {
        [user] + projectCache.keys.sorted().flatMap { key in projectCache[key].map { [$0.project, $0.local] } ?? [] }
    }

    var pending: [String: ProposedChange] {
        get { pendingByScope[scope] ?? [:] }
        set { pendingByScope[scope] = newValue }
    }

    var canUndo: Bool { selectedStore?.canUndo ?? false }
    var hasPending: Bool { !pending.isEmpty }
    var canEditScope: Bool { !isWriting && selectedStore?.isEditable == true }

    func row(_ tweak: Tweak) -> RowState {
        rows[tweak.id] ?? RowState()
    }

    // MARK: Lifecycle

    func start() async {
        await reload()
        await keybindings.reload()
        keybindings.startWatching()
        await restoreSession()
        presentOnboardingIfFirstLaunch()
        startWatching()
        await loadProjectSuggestions()
        await probeClaude()
    }

    func probeClaude() async {
        do {
            claude = .found(try await probe.probe())
        } catch {
            claude = .notFound
        }
        refresh()
    }

    func stop() {
        reloadGeneration += 1
        keybindings.stopWatching()
        for store in stores {
            store.stopWatching()
        }
        isStartingManagedWatcher = false
        managedTask?.cancel()
        managedTask = nil
        managedWatcher?.stop()
        managedWatcher = nil
    }

    // MARK: Reloading

    /// Reads every layer again, off the main actor, and rebuilds the merged settings. True when a file
    /// changed that Pitot did not write. When a newer reload starts first, this one publishes nothing.
    @discardableResult
    func reload() async -> Bool {
        reloadGeneration += 1
        let current = reloadGeneration
        let reader = managedReader
        let managedRead = Task.detached { reader.load() }
        var changed = await user.reload()
        if let projectStores {
            changed = await projectStores.project.reload() || changed
            changed = await projectStores.local.reload() || changed
        }
        let loadedManaged = await managedRead.value
        guard current == reloadGeneration else { return changed }
        managed = loadedManaged
        rebuildEffective()
        reconcilePending()
        return changed
    }

    func handleFileChange() async {
        if await reload() { externalChangeBanner = true }
        startWatching()
    }

    /// Watches each open layer and the managed file. Folders that do not exist yet are skipped and
    /// picked up on a later call. Watchers are set up off the main actor.
    func startWatching() {
        let onChange: @MainActor () async -> Void = { [weak self] in await self?.handleFileChange() }
        user.startWatching(onChange)
        projectStores?.project.startWatching(onChange)
        projectStores?.local.startWatching(onChange)
        guard managedWatcher == nil, !isStartingManagedWatcher else { return }
        isStartingManagedWatcher = true
        let url = services.managedFolder.appendingPathComponent(ManagedSettingsReader.fileName)
        managedTask = Task { [weak self] in
            let made = await Task.detached { try? FileWatcher(url: url) }.value
            guard let made, let changes = self?.adoptManagedWatcher(made) else {
                made?.stop()
                self?.isStartingManagedWatcher = false
                return
            }
            await self?.handleFileChange()
            for await _ in changes {
                await self?.handleFileChange()
            }
        }
    }

    /// Nil when `stop()` ran while the watcher was being set up.
    private func adoptManagedWatcher(_ watcher: FileWatcher) -> AsyncStream<FileChange>? {
        guard isStartingManagedWatcher else { return nil }
        isStartingManagedWatcher = false
        managedWatcher = watcher
        return watcher.changes
    }

    func rebuildEffective() {
        let projectLayers = [projectStores?.project.layer, projectStores?.local.layer].compactMap { $0 }
        effective = EffectiveSettings(layers: [user.layer, managed] + projectLayers)
    }

    /// Drops pending changes each layer now already holds, then recomputes rows and the review.
    func reconcilePending() {
        for (kind, changes) in pendingByScope {
            guard let document = store(for: kind)?.editDocument else { continue }
            pendingByScope[kind] = changes.filter { id, change in
                catalog.tweak(id: id)?.operation(for: change.value, in: document) != nil
            }
        }
        refresh()
    }

    func refresh() {
        guard let store = selectedStore else {
            rows = [:]
            review = ReviewPlan()
            return
        }
        let context = RowContext(scope: scope, layer: store, effective: effective, claude: claude)
        let plan = ReviewPlan.make(catalog: catalog, context: context, pending: pending)
        var states: [String: RowState] = [:]
        for tweak in catalog.tweaks {
            states[tweak.id] = RowState.make(
                tweak, context: context, pending: pending[tweak.id], resolution: plan.resolution, refusal: refusals[tweak.id])
        }
        review = plan
        rows = states
    }

    static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws(SettingsFileError) -> T
    ) async -> Result<T, SettingsFileError> {
        await Task.detached { Result { () throws(SettingsFileError) in try work() } }.value
    }
}
