import Foundation
import Testing

@testable import PitotCore

@Suite("Probe")
struct ClaudeProbeTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    @discardableResult
    private func fakeClaude(in folder: String, script: String, executable: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: directory.file(folder), withIntermediateDirectories: true)
        let url = try directory.write("\(folder)/claude", "#!/bin/sh\n\(script)\n")
        chmod(url.path, executable ? 0o755 : 0o644)
        return url
    }

    @Test func defaultSearchPathsAreFixedAndInOrder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(
            ClaudeProbe.defaultSearchPaths.map(\.path) == [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
    }

    @Test func usesFirstExecutableInSearchOrder() async throws {
        let notExecutable = try fakeClaude(in: "a", script: "echo '9.9.9 (Claude Code)'", executable: false)
        let expected = try fakeClaude(in: "b", script: "echo '2.1.291 (Claude Code)'")
        let later = try fakeClaude(in: "c", script: "echo '3.0.0 (Claude Code)'")
        let missing = directory.file("none/claude")
        let probe = ClaudeProbe(searchPaths: [missing, notExecutable, expected, later])

        let installation = try await probe.probe()

        #expect(installation.executable == expected)
        #expect(installation.version == ClaudeVersion(parsing: "2.1.291"))
        #expect(installation.version.description == "2.1.291")
    }

    @Test func reportsNotFoundWithSearchedPaths() async {
        let paths = [directory.file("x/claude"), directory.file("y/claude")]
        await #expect(throws: ClaudeProbeError.notFound(searched: paths.map(\.path))) {
            try await ClaudeProbe(searchPaths: paths).probe()
        }
    }

    @Test func timesOutAndStopsTheProcess() async throws {
        let url = try fakeClaude(in: "slow", script: "exec sleep 30")
        let start = ContinuousClock.now
        await #expect(throws: ClaudeProbeError.timedOut(path: url.path)) {
            try await ClaudeProbe(searchPaths: [url], timeout: .milliseconds(300)).probe()
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// A child left in the background inherits standard output. Waiting for the pipe to close would wait
    /// 30 seconds for it. The bound is loose because the first run of a new script can be slow to start.
    @Test func returnsPromptlyAndKillsAChildLeftInTheBackground() async throws {
        let childFile = directory.file("child.pid")
        let url = try fakeClaude(in: "spawner", script: "sleep 30 &\necho $! > '\(childFile.path)'\necho '2.1.291 (Claude Code)'")
        let start = ContinuousClock.now

        let installation = try await ClaudeProbe(searchPaths: [url]).probe()

        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(installation.version == ClaudeVersion(parsing: "2.1.291"))
        let child = try #require(pid_t(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await isGone(child))
    }

    /// The time limit leaves the script room to start its child first: a new script can take a moment to start.
    @Test func timeoutKillsTheChildrenToo() async throws {
        let childFile = directory.file("child.pid")
        let url = try fakeClaude(in: "hanging", script: "sleep 30 &\necho $! > '\(childFile.path)'\nexec sleep 30")

        await #expect(throws: ClaudeProbeError.timedOut(path: url.path)) {
            try await ClaudeProbe(searchPaths: [url], timeout: .seconds(3)).probe()
        }

        let child = try #require(pid_t(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await isGone(child))
    }

    /// A killed child whose parent already exited is reaped by launchd, which can take a moment.
    private func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<40 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func reportsNonZeroExit() async throws {
        let url = try fakeClaude(in: "failing", script: "exit 3")
        await #expect(throws: ClaudeProbeError.exitedWithStatus(path: url.path, status: 3)) {
            try await ClaudeProbe(searchPaths: [url]).probe()
        }
    }

    @Test func reportsUnrecognizedOutput() async throws {
        let url = try fakeClaude(in: "odd", script: "echo hello")
        await #expect(throws: ClaudeProbeError.unrecognizedVersion(path: url.path)) {
            try await ClaudeProbe(searchPaths: [url]).probe()
        }
    }

    @Test func reportsLaunchFailure() async throws {
        let url = try fakeClaude(in: "broken", script: "")
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0]).write(to: url)
        chmod(url.path, 0o755)
        await #expect(throws: ClaudeProbeError.launchFailed(path: url.path)) {
            try await ClaudeProbe(searchPaths: [url]).probe()
        }
    }

    @Test(
        "parses version output",
        arguments: [
            ("2.1.291 (Claude Code)", "2.1.291"),
            ("1.0.0\n", "1.0.0"),
            ("  2.0.0-beta.1 (Claude Code)\nextra", "2.0.0-beta.1"),
            ("3.4.5+build.7", "3.4.5"),
        ])
    func parsesVersion(output: String, expected: String) throws {
        #expect(try #require(ClaudeVersion(parsing: output)).description == expected)
    }

    @Test("rejects malformed version output", arguments: ["", "Claude Code", "1.2", "v1.2.3", "1.2.x", "1..2"])
    func rejectsMalformedVersion(output: String) {
        #expect(ClaudeVersion(parsing: output) == nil)
    }

    @Test func versionsCompareBySemver() throws {
        let versions = try ["2.1.291", "2.1.300", "2.0.0-beta.1", "2.0.0", "10.0.0"].map { try #require(ClaudeVersion(parsing: $0)) }
        #expect(versions.sorted().map(\.description) == ["2.0.0-beta.1", "2.0.0", "2.1.291", "2.1.300", "10.0.0"])
    }

    @Test(
        "finds the installed claude on this Mac",
        .enabled(if: ClaudeProbe.defaultSearchPaths.contains { FileManager.default.isExecutableFile(atPath: $0.path) })
    )
    func realInstallation() async throws {
        let installation = try await ClaudeProbe().probe()
        #expect(installation.version.major >= 1)
    }
}
