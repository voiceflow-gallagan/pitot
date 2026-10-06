import Foundation

/// Asks git whether a file is ignored, with `git check-ignore`.
///
/// The project may be an untrusted repository, so git runs without a shell, with fsmonitor off, with
/// a minimal environment and with a time limit. A slow or stuck git counts as "unknown", which gives
/// no warning.
struct GitIgnoreCheck: Sendable {
    /// Nil when no git is installed; the check then reports nothing.
    let git: URL?
    var timeout: Duration = .seconds(3)
    /// The environment the check starts from. Only the variables in `passedVariables` reach git.
    var parentEnvironment: [String: String] = ProcessInfo.processInfo.environment

    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// HOME and XDG_CONFIG_HOME locate the user's own global ignore rules, which decide whether a file
    /// is committed. Every other variable, `GIT_DIR` and the other `GIT_*` ones included, is dropped.
    static let passedVariables = ["HOME", "XDG_CONFIG_HOME"]

    /// The first git found. `/usr/bin/git` is left out on purpose: without the developer tools it is a
    /// stub that opens an install dialog.
    static var system: GitIgnoreCheck {
        GitIgnoreCheck(git: candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static var candidates: [URL] {
        let developer = URL(fileURLWithPath: "/var/db/xcode_select_link").resolvingSymlinksInPath()
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/git"),
            URL(fileURLWithPath: "/usr/local/bin/git"),
            developer.appendingPathComponent("usr/bin/git"),
            URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"),
        ]
    }

    static func arguments(for relativePath: String) -> [String] {
        ["-c", "core.fsmonitor=false", "check-ignore", "-q", "--", relativePath]
    }

    static func environment(from parent: [String: String]) -> [String: String] {
        var environment = ["PATH": path]
        for name in passedVariables {
            if let value = parent[name] { environment[name] = value }
        }
        return environment
    }

    /// True when git ignores `relativePath` inside `folder`, false when it does not, nil when there is
    /// no git, `folder` is not in a repository, or git did not answer in time. The path is relative
    /// because git compares it with the repository root after resolving symbolic links, so `/var/...`
    /// would count as outside `/private/var/...`.
    func isIgnored(_ relativePath: String, in folder: URL) async -> Bool? {
        guard let git else { return nil }
        let environment = Self.environment(from: parentEnvironment)
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.run(git, path: relativePath, folder: folder, environment: environment, timeout: timeout))
            }
        }
    }

    private static func run(_ git: URL, path: String, folder: URL, environment: [String: String], timeout: Duration) -> Bool? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments(for: path)
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard exited.wait(timeout: .now() + interval(timeout)) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(1)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
