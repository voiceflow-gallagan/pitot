import PitotCore
import Foundation
import Testing
import os

@testable import Pitot

@MainActor
struct BackgroundIOTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PitotIO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func script(_ text: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("git")
        try "#!/bin/sh\n\(text)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: git check

    @Test func stuckGitTimesOutAsUnknown() async throws {
        let folder = try folder()
        let check = GitIgnoreCheck(git: try script("sleep 10", in: folder), timeout: .milliseconds(400))
        let start = ContinuousClock.now
        #expect(await check.isIgnored(".claude/settings.local.json", in: folder) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func gitRunsWithSafeArgumentsAndAMinimalEnvironment() async throws {
        let folder = try folder()
        let argsFile = folder.appendingPathComponent("args.txt")
        let envFile = folder.appendingPathComponent("env.txt")
        let git = try script("echo \"$@\" > '\(argsFile.path)'\nenv > '\(envFile.path)'\nexit 1", in: folder)
        let parent = ["GIT_DIR": "/elsewhere/.git", "GIT_WORK_TREE": "/elsewhere", "HOME": folder.path, "SECRET_TOKEN": "x", "PATH": "/evil"]
        let check = GitIgnoreCheck(git: git, parentEnvironment: parent)

        #expect(await check.isIgnored(".claude/settings.local.json", in: folder) == false)
        let arguments = try String(contentsOf: argsFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(arguments == "-c core.fsmonitor=false check-ignore -q -- .claude/settings.local.json")
        let environment = try String(contentsOf: envFile, encoding: .utf8)
        #expect(!environment.contains("GIT_DIR") && !environment.contains("GIT_WORK_TREE") && !environment.contains("SECRET_TOKEN"))
        #expect(environment.contains("PATH=\(GitIgnoreCheck.path)"))
        #expect(GitIgnoreCheck.environment(from: parent) == ["PATH": GitIgnoreCheck.path, "HOME": folder.path])
    }

    // MARK: reads off the main actor

    @Test func slowReadDoesNotBlockTheMainActorAndStaleResultsAreDropped() async throws {
        let folder = try folder()
        let url = folder.appendingPathComponent("settings.json")
        try "{\n  \"model\": \"opus\"\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = LayerStore(kind: .user, project: nil, url: url, backupRoot: folder.appendingPathComponent("Backups")) { file, id, url in
            let read = LayerStore.read(file, id: id, url: url)
            if calls.withLock({ count -> Int in
                count += 1
                return count
            }) == 1 {
                Thread.sleep(forTimeInterval: 0.8)
            }
            return read
        }

        let slow = Task { await store.reload() }
        let start = ContinuousClock.now
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ContinuousClock.now - start < .milliseconds(600))

        try "{\n  \"model\": \"sonnet\"\n}\n".write(to: url, atomically: true, encoding: .utf8)
        await store.reload()
        #expect(store.snapshot?.document.value(at: ["model"]) == "sonnet")
        #expect(await slow.value == false)
        #expect(store.snapshot?.document.value(at: ["model"]) == "sonnet")
    }

    @Test func projectsFileOverTheLimitGivesNoSuggestions() throws {
        let folder = try folder()
        let url = folder.appendingPathComponent("claude.json")
        let padding = String(repeating: " ", count: ClaudeJSONProjects.sizeLimit)
        try "{\"projects\": {\"\(folder.path)\": {}}}\(padding)".write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeJSONProjects(url: url).projectPaths().isEmpty)

        try "{\"projects\": {\"\(folder.path)\": {}}}".write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeJSONProjects(url: url).projectPaths() == [folder.path])
    }

    // MARK: sandbox copies

    @Test func sandboxCopiesArePrivateFromTheStart() throws {
        let folder = try folder()
        let source = folder.appendingPathComponent("source.json")
        try "{}\n".write(to: source, atomically: true, encoding: .utf8)
        let sandbox = folder.appendingPathComponent("Sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let copy = sandbox.appendingPathComponent("settings.json")

        #expect(LaunchConfiguration.copySettings(from: source, to: copy) == nil)
        #expect(try mode(of: copy) == 0o600)
        #expect(try mode(of: sandbox) == 0o700)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{}\n")

        #expect(LaunchConfiguration.copySettings(from: source, to: copy) == nil)
        #expect(try mode(of: copy) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    private func mode(of url: URL) throws -> Int {
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(permissions).intValue & 0o777
    }
}
