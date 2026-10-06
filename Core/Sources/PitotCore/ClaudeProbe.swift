import Foundation

public struct ClaudeVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    /// Parses the first token of the first line, such as `2.1.291` in `2.1.291 (Claude Code)`.
    /// Build metadata after `+` is dropped.
    public init?(parsing output: String) {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let token = firstLine.split(whereSeparator: \.isWhitespace).first else { return nil }
        let withoutBuild = token.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
            numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2])
        else { return nil }
        if parts.count == 2, parts[1].isEmpty { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    /// Orders by numbers, then a prerelease before its release. Prerelease labels compare as text.
    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?): return left < right
        }
    }
}

public struct ClaudeInstallation: Sendable, Equatable {
    public let executable: URL
    public let version: ClaudeVersion
}

public enum ClaudeProbeError: Error, Equatable, Sendable {
    case notFound(searched: [String])
    case launchFailed(path: String)
    case timedOut(path: String)
    case exitedWithStatus(path: String, status: Int32)
    case unrecognizedVersion(path: String)
}

/// Finds the `claude` CLI at fixed install paths and reads its version.
/// It never consults the shell `PATH`, which is minimal when the app starts from Finder.
public struct ClaudeProbe: Sendable {
    public static let defaultSearchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
        URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        URL(fileURLWithPath: "/usr/local/bin/claude"),
    ]

    public let searchPaths: [URL]
    public let timeout: Duration

    public init(searchPaths: [URL] = ClaudeProbe.defaultSearchPaths, timeout: Duration = .seconds(5)) {
        self.searchPaths = searchPaths
        self.timeout = timeout
    }

    public func locate() throws(ClaudeProbeError) -> URL {
        guard let found = searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw .notFound(searched: searchPaths.map(\.path))
        }
        return found
    }

    /// Runs `claude --version` on a background thread and waits at most `timeout`.
    public func probe() async throws(ClaudeProbeError) -> ClaudeInstallation {
        let executable = try locate()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<ClaudeInstallation, ClaudeProbeError>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { () throws(ClaudeProbeError) in try readVersion(of: executable) })
            }
        }
        return try result.get()
    }

    private func readVersion(of executable: URL) throws(ClaudeProbeError) -> ClaudeInstallation {
        let output = try run(executable, arguments: ["--version"])
        guard let version = ClaudeVersion(parsing: String(decoding: output, as: UTF8.self)) else {
            throw .unrecognizedVersion(path: executable.path)
        }
        return ClaudeInstallation(executable: executable, version: version)
    }

    private func run(_ executable: URL, arguments: [String]) throws(ClaudeProbeError) -> Data {
        guard let child = GroupedChild(spawning: executable, arguments: arguments) else {
            throw .launchFailed(path: executable.path)
        }
        switch child.collectOutput(until: .now + timeout) {
        case .timedOut:
            throw .timedOut(path: executable.path)
        case .exited(let status, let output):
            guard status == 0 else { throw .exitedWithStatus(path: executable.path, status: status) }
            return output
        }
    }
}

/// A program started in its own process group, with standard output on a pipe. The whole group is
/// killed when the program exits or runs out of time, so a child it left in the background can neither
/// keep the pipe open nor outlive the probe. No thread waits on the pipe: one loop polls it and the exit.
private struct GroupedChild {
    enum Outcome {
        case exited(status: Int32, output: Data)
        case timedOut
    }

    /// How long output may still arrive after the program exited, from a child that left the group.
    static let drainAfterExit: Duration = .milliseconds(500)

    let pid: pid_t
    let output: Int32

    /// Nil when the program cannot start. Standard input and error are `/dev/null`; no other descriptor is inherited.
    init?(spawning executable: URL, arguments: [String]) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environment)
        close(ends[1])
        guard spawned == 0 else {
            close(ends[0])
            return nil
        }
        self.pid = pid
        output = ends[0]
        guard fcntl(output, F_SETFL, O_NONBLOCK) != -1 else {
            killGroup()
            _ = reap()
            close(output)
            return nil
        }
    }

    /// Reads the output until the program has exited and the pipe is closed, or `drainAfterExit` has passed.
    /// Always kills the group, reaps the program and closes the pipe.
    func collectOutput(until deadline: ContinuousClock.Instant) -> Outcome {
        defer { close(output) }
        var data = Data()
        var status: Int32?
        var stopReading = deadline
        while true {
            let isOpen = drain(into: &data)
            if status == nil, hasExited() {
                killGroup()
                status = reap()
                stopReading = min(deadline, .now + Self.drainAfterExit)
            }
            if let status, !isOpen || ContinuousClock.now >= stopReading {
                return .exited(status: status, output: data)
            }
            if status == nil, ContinuousClock.now >= deadline {
                killGroup()
                _ = reap()
                return .timedOut
            }
            if isOpen {
                var request = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                poll(&request, 1, 20)
            } else {
                usleep(20_000)
            }
        }
    }

    /// Appends what the pipe holds now. False once every writer has closed it.
    private func drain(into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                return false
            } else if errno != EINTR {
                return errno == EAGAIN
            }
        }
    }

    /// Leaves the program unreaped, so its process group id stays reserved until `killGroup` is done.
    private func hasExited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    private func killGroup() {
        kill(-pid, SIGKILL)
    }

    /// The exit code, or the number of the signal that ended the program, as `Process.terminationStatus` gives.
    private func reap() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {
            continue
        }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
    }
}
