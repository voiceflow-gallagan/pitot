import PitotCore
import Foundation
import Testing

@testable import Pitot

/// A model over a settings file in a fresh temp folder, with the bundled catalog unless told otherwise.
@MainActor
struct ModelFixture {
    static let initial = "{\n  \"model\": \"opus\",\n  \"showThinkingSummaries\": false\n}\n"

    let model: SettingsModel
    let url: URL
    let folder: URL

    let recent: MemoryRecentProjects

    /// `claudeVersion` installs a fake `claude` that prints that version; without it, no Claude Code is found.
    /// Without `setupQuestions`, the bundled questions are used when they fit the catalog.
    /// `managed` is the content of `managed-settings.json` in the fixture's managed folder; without it there is none.
    static func make(
        _ settings: String = initial,
        catalog: Catalog? = nil,
        setupQuestions: OnboardingFile? = nil,
        launchFlags: OnboardingFlagStore? = nil,
        claudeVersion: String? = nil,
        managed: String? = nil,
        keybindings: String? = nil,
        suggestions: ProjectSuggestionSource = NoProjectSuggestions(),
        gitCheck: GitIgnoreCheck = GitIgnoreCheck(git: nil),
        session: SessionStore? = nil
    ) async throws -> ModelFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PitotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("settings.json")
        try settings.write(to: url, atomically: true, encoding: .utf8)
        var searchPaths: [URL] = []
        if let claudeVersion {
            let script = folder.appendingPathComponent("claude")
            try "#!/bin/sh\necho '\(claudeVersion) (Claude Code)'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            searchPaths = [script]
        }
        let configuration = LaunchConfiguration(
            settingsURL: url,
            backupRoot: folder.appendingPathComponent("Backups", isDirectory: true),
            mode: .custom,
            setupError: nil
        )
        let managedFolder = folder.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
        if let managed {
            try managed.write(to: managedFolder.appendingPathComponent("managed-settings.json"), atomically: true, encoding: .utf8)
        }
        if let keybindings {
            try keybindings.write(to: folder.appendingPathComponent("keybindings.json"), atomically: true, encoding: .utf8)
        }
        let recent = MemoryRecentProjects()
        let services = LayerServices(managedFolder: managedFolder, recentProjects: recent, projectSuggestions: suggestions, gitCheck: gitCheck)
        let catalog = try catalog ?? bundledCatalog()
        let questions = setupQuestions.map { Result<OnboardingFile, CatalogLoadFailure>.success($0) }
            ?? CatalogResource.loadSetupQuestions(bundle: Bundle(for: SettingsModel.self), catalog: catalog)
        let model = SettingsModel(
            catalog: catalog, keybindingsCatalog: try bundledKeybindings(), unverified: try bundledUnverified(), configuration: configuration,
            setupQuestions: questions, launchFlags: launchFlags, services: services, session: session,
            probe: ClaudeProbe(searchPaths: searchPaths))
        await model.reload()
        await model.keybindings.reload()
        return ModelFixture(model: model, url: url, folder: folder, recent: recent)
    }

    /// A project folder in the fixture. Nil content leaves that file out, and no content at all leaves out `.claude`.
    func makeProject(shared: String? = nil, local: String? = nil) throws -> URL {
        let project = folder.appendingPathComponent("Project-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let claude = project.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if shared != nil || local != nil {
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        }
        try shared?.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try local?.write(to: claude.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)
        return project
    }

    func tweak(_ id: String) throws -> Tweak {
        try #require(model.catalog.tweak(id: id))
    }

    func text() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file as decoded JSON, so tests can compare content without caring about layout.
    func decoded() throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    func backupCount() throws -> Int {
        let backups = folder.appendingPathComponent("Backups", isDirectory: true)
        let files = FileManager.default.enumerator(at: backups, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
}

func bundledCatalog() throws -> Catalog {
    try CatalogResource.load(bundle: Bundle(for: SettingsModel.self)).get()
}

func bundledKeybindings() throws -> KeybindingsCatalog {
    try CatalogResource.loadKeybindings(bundle: Bundle(for: SettingsModel.self)).get()
}

func bundledUnverified() throws -> UnverifiedCatalog {
    try CatalogResource.loadUnverified(bundle: Bundle(for: SettingsModel.self)).get()
}

/// Two sandbox rows: the second stays disabled until the first is on.
let sandboxCatalog = Catalog(
    researchDate: "2026-10-06",
    claudeCodeVersionChecked: "2.1.291",
    tweaks: [
        Tweak(
            id: "sandbox.enabled", location: .setting(path: ["sandbox", "enabled"]), valueType: .bool,
            defaultDescription: "false: no sandbox.", title: "Sandbox", description: "Run Bash commands in a sandbox.",
            category: "Safety", risks: [.security], docURL: "https://code.claude.com/docs/en/settings"),
        Tweak(
            id: "sandbox.failIfUnavailable", location: .setting(path: ["sandbox", "failIfUnavailable"]), valueType: .bool,
            defaultDescription: "false: run without it.", title: "Fail without sandbox", description: "Stop when the sandbox cannot start.",
            category: "Safety", risks: [.security],
            requires: [Tweak.Requirement(tweakId: "sandbox.enabled", equals: true, behavior: .disable, reason: "Needs the sandbox on.")],
            docURL: "https://code.claude.com/docs/en/settings"),
    ]
)

@MainActor
final class MemoryOnboardingFlags: OnboardingFlagStore {
    var onboardingSeen = false
}

@MainActor
final class MemoryRecentProjects: RecentProjectStore {
    var paths: [String] = []
}

@MainActor
final class MemorySession: SessionStore {
    var section: String?
    var scope: String?
    var projectPath: String?
}
