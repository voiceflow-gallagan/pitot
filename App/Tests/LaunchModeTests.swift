import Foundation
import PitotCore
import SwiftUI
import Testing

@testable import Pitot

struct LaunchModeTests {
    private let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)

    @Test func releaseEditsTheRealFilesAndDebugWorksOnACopy() {
        #expect(LaunchConfiguration.fileMode(environment: [:], arguments: [], isDebugBuild: false) == .real)
        #expect(LaunchConfiguration.fileMode(environment: [:], arguments: [], isDebugBuild: true) == .copy)
    }

    @Test(arguments: [true, false])
    func argumentsAndEnvironmentOverrideTheDefault(isDebugBuild: Bool) {
        func mode(_ environment: [String: String], _ arguments: [String] = []) -> FileMode {
            LaunchConfiguration.fileMode(environment: environment, arguments: arguments, isDebugBuild: isDebugBuild)
        }
        let byDefault: FileMode = isDebugBuild ? .copy : .real
        #expect(mode([:], ["--use-real-settings"]) == .real)
        #expect(mode([:], ["--use-settings-copy"]) == .copy)
        #expect(mode(["PITOT_USE_COPY": "1"]) == .copy)
        #expect(mode(["PITOT_USE_COPY": "1"], ["--use-real-settings"]) == .copy)
        #expect(mode([:], ["--use-real-settings", "--use-settings-copy"]) == .copy)
        #expect(mode(["PITOT_USE_COPY": "0"]) == byDefault)
        #expect(mode(["PITOT_USE_COPY": ""]) == byDefault)
        #expect(mode(["PITOT_SETTINGS_PATH": "/tmp/settings.json"], ["--use-real-settings"]) == .custom)
        #expect(mode(["PITOT_SETTINGS_PATH": "/tmp/settings.json", "PITOT_USE_COPY": "1"]) == .custom)
        #expect(mode(["PITOT_SETTINGS_PATH": ""]) == byDefault)
    }

    @Test func releaseDefaultPointsAtTheRealFiles() {
        let configuration = LaunchConfiguration.resolve(environment: [:], arguments: [], isDebugBuild: false)
        #expect(configuration.mode == .real)
        #expect(configuration.settingsURL == claude.appendingPathComponent("settings.json"))
        #expect(configuration.keybindingsURL == claude.appendingPathComponent("keybindings.json"))
        #expect(configuration.backupRoot == SettingsFile.defaultBackupRoot)
        #expect(configuration.managedFolder == ManagedSettingsReader.defaultFolder)
        #expect(configuration.setupError == nil)
    }

    @Test func pathOverridesStillWinInARelease() {
        let environment = [
            "PITOT_SETTINGS_PATH": "/tmp/pitot/settings.json",
            "PITOT_KEYBINDINGS_PATH": "/tmp/pitot/keys.json",
            "PITOT_MANAGED_DIR": "/tmp/pitot/managed",
        ]
        let configuration = LaunchConfiguration.resolve(environment: environment, arguments: ["--use-real-settings"], isDebugBuild: false)
        #expect(configuration.mode == .custom)
        #expect(configuration.settingsURL.path == "/tmp/pitot/settings.json")
        #expect(configuration.keybindingsURL.path == "/tmp/pitot/keys.json")
        #expect(configuration.managedFolder.path == "/tmp/pitot/managed")
        #expect(!UpdaterPolicy.mayStart(publicKey: "key", environment: environment))
    }

    @Test func realFileInAReleaseGetsACalmLabel() {
        let settings = claude.appendingPathComponent("settings.json")
        let release = FileLabelStyle.make(scope: .user, mode: .real, project: "", url: settings, isDebugBuild: false)
        #expect(release.title == "Editing ~/.claude/settings.json")
        #expect(release.note == "Pitot backs up the file before every change. Undo is in the History panel.")
        #expect(release.path == nil)
        #expect(release.color != .red)
        #expect(!release.symbol.contains("exclamationmark"))

        let debug = FileLabelStyle.make(scope: .user, mode: .real, project: "", url: settings, isDebugBuild: true)
        #expect(debug.title == "REAL FILE")
        #expect(debug.color == .red)
        #expect(debug.path == settings.path)
    }

    @Test(arguments: [true, false])
    func copyAndProjectLabelsDoNotDependOnTheBuild(isDebugBuild: Bool) {
        let copy = FileLabelStyle.make(scope: .user, mode: .copy, project: "", url: URL(fileURLWithPath: "/tmp/copy.json"), isDebugBuild: isDebugBuild)
        #expect(copy.title == "Working on a COPY")
        #expect(copy.color == .yellow)
        #expect(copy.path == "/tmp/copy.json")

        let shared = URL(fileURLWithPath: "/work/app/.claude/settings.json")
        let project = FileLabelStyle.make(scope: .project, mode: .real, project: "app", url: shared, isDebugBuild: isDebugBuild)
        #expect(project.title == "Project settings, shared · app")
        #expect(project.path == shared.path)
        #expect(project.note == nil)
    }

    @Test func keybindingsTitleIsCalmForARealFileInARelease() {
        #expect(FileMode.real.keybindingsTitle(isDebugBuild: false) == "Keybindings")
        #expect(FileMode.real.keybindingsTitle(isDebugBuild: true) == "Keybindings · REAL FILE")
        #expect(FileMode.copy.keybindingsTitle(isDebugBuild: false) == "Keybindings · working on a COPY")
    }
}
