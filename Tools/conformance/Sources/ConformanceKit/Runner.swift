import PitotCore
import Foundation

public struct ConformanceError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public enum Workspace {
    /// The real path, so it matches the folder name Claude Code derives from its working directory.
    public static func create(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let resolved = realpath(directory.path, nil) else {
            throw ConformanceError("cannot resolve \(directory.path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Writes the probe script and the batch's settings files, and empties its output folder so no
    /// probe file from an earlier run is mistaken for a hook that ran.
    public static func write(_ plan: BatchPlan) throws {
        let manager = FileManager.default
        try Data(BatchPlan.probeScript.utf8).write(to: plan.probeScriptURL)
        if manager.fileExists(atPath: plan.outputDirectory.path) {
            try manager.removeItem(at: plan.outputDirectory)
        }
        try manager.createDirectory(at: plan.outputDirectory, withIntermediateDirectories: true)
        for layer in Catalog.layers {
            let url = plan.settingsURL(for: layer)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(plan.bytes(for: layer)).write(to: url)
        }
        for url in [plan.streamURL, plan.stderrURL] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
}

public enum ClaudeRunner {
    /// The environment for Claude Code: this process's, without variables that could fake a result.
    public static func environment(from base: [String: String]) -> [String: String] {
        base.filter { !$0.key.hasPrefix("PITOT_CONF_") && $0.key != "CONFORMANCE_MUTATE" }
    }

    public static func commandLine(executable: URL, plan: BatchPlan) -> String {
        "cd \(Shell.quote(plan.projectDirectory.path)) && \(Shell.quote(executable.path)) "
            + plan.arguments().map(Shell.quote).joined(separator: " ")
    }

    /// Runs Claude Code in the batch folder with output to files, so a full pipe never blocks it.
    /// Returns nil after a clean exit, or what went wrong.
    public static func run(_ plan: BatchPlan, executable: URL, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = plan.arguments()
        process.currentDirectoryURL = plan.projectDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        do {
            FileManager.default.createFile(atPath: plan.streamURL.path, contents: nil)
            FileManager.default.createFile(atPath: plan.stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: plan.streamURL)
            let stderr = try FileHandle(forWritingTo: plan.stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
        } catch {
            return "launch failed: \(error.localizedDescription)"
        }
        let deadline = ContinuousClock.now + BatchPlan.timeout
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return "timed out after \(BatchPlan.timeout)"
        }
        return process.terminationStatus == 0 ? nil : "exit status \(process.terminationStatus)"
    }
}

/// The folders Claude Code keeps per project under `~/.claude/projects`, to remove the empty ones a
/// run created for its throwaway project.
public struct ProjectFolders {
    public static let maximumNameLength = 200

    public let root: URL

    public init(environment: [String: String]) {
        let configDirectory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        root = configDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    /// Claude Code's folder name for a project path: every UTF-16 unit that is not an ASCII letter or
    /// digit becomes `-`. Longer names get a hash suffix this tool does not compute, so it returns nil.
    public static func name(forProject path: String) -> String? {
        let units = path.utf16.map { unit -> UInt8 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: UInt8(unit)
            default: UInt8(ascii: "-")
            }
        }
        return units.count <= maximumNameLength ? String(decoding: units, as: UTF8.self) : nil
    }

    public func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    /// Removes the folder of each project that was not there `before` and holds only empty folders.
    /// Returns what it removed and what it left because it holds files.
    public func removeEmpty(projects: [URL], before: Set<String>) -> (removed: [String], kept: [String]) {
        var removed: [String] = []
        var kept: [String] = []
        for project in projects {
            guard let name = Self.name(forProject: project.path), !before.contains(name) else { continue }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            if holdsOnlyFolders(folder), (try? FileManager.default.removeItem(at: folder)) != nil {
                removed.append(name)
            } else {
                kept.append(name)
            }
        }
        return (removed, kept)
    }

    private func holdsOnlyFolders(_ folder: URL) -> Bool {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let item as URL in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        }
        return true
    }
}
