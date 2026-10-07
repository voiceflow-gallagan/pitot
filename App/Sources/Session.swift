import Foundation
import PitotCore

/// What Pitot reopens at the next launch: the selected section, the scope and the project folder.
/// It keeps names and a folder path only, never the content of a file.
@MainActor
protocol SessionStore: AnyObject {
    var section: String? { get set }
    var scope: String? { get set }
    var projectPath: String? { get set }
}

@MainActor
final class UserDefaultsSession: SessionStore {
    static let sectionKey = "lastSection"
    static let scopeKey = "lastScope"
    static let projectKey = "lastProject"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var section: String? {
        get { defaults.string(forKey: Self.sectionKey) }
        set { defaults.set(newValue, forKey: Self.sectionKey) }
    }

    var scope: String? {
        get { defaults.string(forKey: Self.scopeKey) }
        set { defaults.set(newValue, forKey: Self.scopeKey) }
    }

    var projectPath: String? {
        get { defaults.string(forKey: Self.projectKey) }
        set { defaults.set(newValue, forKey: Self.projectKey) }
    }
}

enum SessionStores {
    /// Nil, like the first-launch flag, for a custom settings path or a test run hosted in the app.
    @MainActor
    static func store(mode: FileMode, environment: [String: String], defaults: UserDefaults = .standard) -> SessionStore? {
        guard mode != .custom, environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return UserDefaultsSession(defaults: defaults)
    }
}

extension SettingsModel {
    /// Selects the section, project and scope of the last launch, when they still exist.
    func restoreSession() async {
        guard let session else { return }
        if let id = session.section, let item = SidebarItem(id: id), sidebarItems.contains(item) {
            select(item)
        }
        let scope = session.scope.flatMap(SettingsLayerKind.init(rawValue:))
        if let path = session.projectPath {
            if await Task.detached(operation: { ProjectChoices.exists(path) }).value {
                await selectProject(URL(fileURLWithPath: path, isDirectory: true))
            } else {
                session.projectPath = nil
            }
        }
        if let scope { selectScope(scope) }
    }
}
