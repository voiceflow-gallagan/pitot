import PitotCore
import SwiftUI

@main
struct PitotApp: App {
    @State private var launch = AppLaunch.loading
    @State private var window = WindowState()
    @State private var updates = UpdatesModel(
        publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        environment: ProcessInfo.processInfo.environment,
        makeUpdater: { SparkleUpdater() })

    var body: some Scene {
        Window("Pitot", id: "main") {
            Group {
                switch launch {
                case .loading: ProgressView("Starting Pitot…").frame(minWidth: 600, minHeight: 400)
                case .ready(let model): ContentView(model: model)
                case .failed(let message): CatalogErrorView(message: message)
                }
            }
            .background(WindowReader(state: window))
            .task {
                guard case .loading = launch else { return }
                launch = await AppLaunch.start()
                updates.start()
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            PitotCommands(model: launch.model, window: window, updates: updates)
        }

        Window("About Pitot", id: "about") {
            AboutView(updates: updates, info: AboutInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]))
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum AppLaunch {
    case loading
    case ready(SettingsModel)
    case failed(String)

    var model: SettingsModel? {
        if case .ready(let model) = self { return model }
        return nil
    }

    /// Everything the model needs that comes from disk: the bundled tables, the sandbox copies and
    /// the git lookup. It is gathered off the main actor.
    private struct Prepared: Sendable {
        let catalog: Catalog
        let keybindings: KeybindingsCatalog
        let unverified: UnverifiedCatalog
        let questions: Result<OnboardingFile, CatalogLoadFailure>
        let configuration: LaunchConfiguration
        let gitCheck: GitIgnoreCheck
    }

    @MainActor
    static func start() async -> AppLaunch {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let prepared = await Task.detached { prepare(environment: environment, arguments: arguments) }.value
        switch prepared {
        case .success(let prepared):
            let configuration = prepared.configuration
            // ~/.claude.json also holds sign-in data, so it is read only when Pitot edits the real files.
            let suggestions: ProjectSuggestionSource =
                configuration.mode == .real ? ClaudeJSONProjects(url: ClaudeJSONProjects.defaultURL) : NoProjectSuggestions()
            let services = LayerServices(
                managedFolder: configuration.managedFolder, recentProjects: UserDefaultsRecentProjects(),
                projectSuggestions: suggestions, gitCheck: prepared.gitCheck)
            return .ready(
                SettingsModel(
                    catalog: prepared.catalog,
                    keybindingsCatalog: prepared.keybindings,
                    unverified: prepared.unverified,
                    configuration: configuration,
                    setupQuestions: prepared.questions,
                    launchFlags: OnboardingFlags.store(mode: configuration.mode, environment: environment),
                    services: services,
                    session: SessionStores.store(mode: configuration.mode, environment: environment)))
        case .failure(let failure):
            return .failed(failure.message)
        }
    }

    private static func prepare(environment: [String: String], arguments: [String]) -> Result<Prepared, CatalogLoadFailure> {
        CatalogResource.load().flatMap { catalog in
            CatalogResource.loadKeybindings().flatMap { keybindings in
                CatalogResource.loadUnverified().map { unverified in
                    Prepared(
                        catalog: catalog, keybindings: keybindings, unverified: unverified,
                        questions: CatalogResource.loadSetupQuestions(catalog: catalog),
                        configuration: LaunchConfiguration.resolve(environment: environment, arguments: arguments),
                        gitCheck: .system)
                }
            }
        }
    }
}
