import PitotCore
import Foundation

enum FileMode: Equatable, Sendable {
    case copy
    case real
    case custom
}

struct LaunchConfiguration: Sendable {
    let settingsURL: URL
    let backupRoot: URL
    let mode: FileMode
    let setupError: String?
    /// The managed settings folder Pitot reads. `PITOT_MANAGED_DIR` replaces it for tests and manual runs.
    var managedFolder = ManagedSettingsReader.defaultFolder
    /// The keybindings file. Pitot may create it, and the folders on the way, inside its parent folder only.
    /// `PITOT_KEYBINDINGS_PATH` replaces it for tests and manual runs.
    var keybindingsURL: URL

    static let sandboxFolder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("Pitot-Sandbox", isDirectory: true)

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    init(settingsURL: URL, backupRoot: URL, mode: FileMode, setupError: String?, keybindingsURL: URL? = nil) {
        self.settingsURL = settingsURL
        self.backupRoot = backupRoot
        self.mode = mode
        self.setupError = setupError
        self.keybindingsURL = keybindingsURL ?? settingsURL.deletingLastPathComponent().appendingPathComponent("keybindings.json")
    }

    /// Which files Pitot edits. A custom path always wins. Then a request for the copy, then
    /// `--use-real-settings`. Without any of them, a release build edits the real files and a debug
    /// build works on a copy.
    static func fileMode(environment: [String: String], arguments: [String], isDebugBuild: Bool) -> FileMode {
        if let path = environment["PITOT_SETTINGS_PATH"], !path.isEmpty { return .custom }
        let useCopy = environment["PITOT_USE_COPY"].map { !$0.isEmpty && $0 != "0" } ?? false
        if useCopy || arguments.contains("--use-settings-copy") { return .copy }
        if arguments.contains("--use-real-settings") { return .real }
        return isDebugBuild ? .copy : .real
    }

    static func resolve(
        environment: [String: String], arguments: [String], isDebugBuild: Bool = LaunchConfiguration.isDebugBuild
    ) -> LaunchConfiguration {
        var configuration = resolveFile(mode: fileMode(environment: environment, arguments: arguments, isDebugBuild: isDebugBuild), environment: environment)
        if let folder = environment["PITOT_MANAGED_DIR"], !folder.isEmpty {
            configuration.managedFolder = URL(fileURLWithPath: folder, isDirectory: true)
        }
        if let path = environment["PITOT_KEYBINDINGS_PATH"], !path.isEmpty {
            configuration.keybindingsURL = URL(fileURLWithPath: path)
        }
        return configuration
    }

    private static func resolveFile(mode: FileMode, environment: [String: String]) -> LaunchConfiguration {
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let realSettings = claude.appendingPathComponent("settings.json")
        let realKeybindings = claude.appendingPathComponent("keybindings.json")
        if mode == .custom, let path = environment["PITOT_SETTINGS_PATH"] {
            return LaunchConfiguration(
                settingsURL: URL(fileURLWithPath: path),
                backupRoot: sandboxFolder.appendingPathComponent("Backups", isDirectory: true),
                mode: .custom,
                setupError: nil
            )
        }
        if mode == .real {
            return LaunchConfiguration(
                settingsURL: realSettings, backupRoot: SettingsFile.defaultBackupRoot, mode: .real, setupError: nil,
                keybindingsURL: realKeybindings)
        }
        let copy = sandboxFolder.appendingPathComponent("settings.json")
        let keybindingsCopy = sandboxFolder.appendingPathComponent("keybindings.json")
        let errors = [copySettings(from: realSettings, to: copy), copyKeybindings(from: realKeybindings, to: keybindingsCopy)].compactMap { $0 }
        return LaunchConfiguration(
            settingsURL: copy,
            backupRoot: sandboxFolder.appendingPathComponent("Backups", isDirectory: true),
            mode: .copy,
            setupError: errors.isEmpty ? nil : errors.joined(separator: "\n"),
            keybindingsURL: keybindingsCopy
        )
    }

    /// Copies `source` so that no other user can read the copy at any moment: the folder is 0700 and
    /// the file is created with mode 0600 in one step, then renamed into place.
    static func copySettings(from source: URL, to destination: URL) -> String? {
        let folder = destination.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let data = try Data(contentsOf: source)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try writePrivate(data, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else { throw CopyError(code: errno) }
            return nil
        } catch {
            unlink(temporary.path)
            return "Could not copy \(source.path) to the sandbox: \(error.localizedDescription)"
        }
    }

    private struct CopyError: LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
    }

    /// Creates `url`, which must not exist, with mode 0600 and writes `data` to it.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CopyError(code: errno) }
        defer { close(descriptor) }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if let failure { throw CopyError(code: failure) }
        guard fsync(descriptor) == 0 else { throw CopyError(code: errno) }
    }

    /// Copies the real keybindings file when there is one. Without one, an old copy is removed, so the
    /// sandbox starts without a file, like the real folder.
    private static func copyKeybindings(from source: URL, to destination: URL) -> String? {
        guard FileManager.default.fileExists(atPath: source.path) else {
            guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
            do {
                try FileManager.default.removeItem(at: destination)
                return nil
            } catch {
                return "Could not remove the old keybindings copy at \(destination.path): \(error.localizedDescription)"
            }
        }
        return copySettings(from: source, to: destination)
    }
}

enum ClaudeStatus: Equatable {
    case checking
    case found(ClaudeInstallation)
    case notFound

    var version: ClaudeVersion? {
        if case .found(let installation) = self { return installation.version }
        return nil
    }
}
