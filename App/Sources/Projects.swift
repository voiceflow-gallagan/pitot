import PitotCore
import Foundation

/// The project folders the user chose in Pitot, newest first.
@MainActor
protocol RecentProjectStore: AnyObject {
    var paths: [String] { get set }
}

@MainActor
final class UserDefaultsRecentProjects: RecentProjectStore {
    static let key = "recentProjects"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var paths: [String] {
        get { defaults.stringArray(forKey: Self.key) ?? [] }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

extension RecentProjectStore {
    static var limit: Int { 8 }

    func remember(_ folder: URL) {
        paths = Array(([folder.path] + paths.filter { $0 != folder.path }).prefix(Self.limit))
    }
}

/// Project folders Claude Code has seen, used only as suggestions in the project menu.
protocol ProjectSuggestionSource: Sendable {
    /// Paths in the order the source lists them, oldest first.
    func projectPaths() -> [String]
}

struct NoProjectSuggestions: ProjectSuggestionSource {
    func projectPaths() -> [String] { [] }
}

/// Reads the key names of the top-level `projects` object of `~/.claude.json`, and nothing else.
///
/// That file also holds sign-in data. `JSONScanner` only records where each value lies, so no
/// value is ever decoded: the code reads member keys of `projects` and drops the bytes.
/// A file larger than `sizeLimit` gives no suggestions, so a huge file never fills memory.
struct ClaudeJSONProjects: ProjectSuggestionSource {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    static let sizeLimit = 8 * 1024 * 1024

    let url: URL

    func projectPaths() -> [String] {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.sizeLimit + 1), data.count <= Self.sizeLimit else { return [] }
        let document: JSONDocument
        do throws(JSONScanError) {
            document = try JSONScanner.scan(Array(data))
        } catch {
            return []
        }
        guard case .object(let members) = document.root.kind,
            let projects = members.first(where: { $0.key == "projects" }),
            case .object(let entries) = projects.value.kind
        else { return [] }
        return entries.map(\.key)
    }
}

struct ProjectChoice: Identifiable, Equatable {
    enum Source: Equatable {
        case recent
        case claudeCode
    }

    let url: URL
    let source: Source

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum ProjectChoices {
    static let suggestionLimit = 15

    /// Recent folders first, then up to 15 of Claude Code's projects, newest first.
    /// Only folders that still exist are listed, each once.
    static func make(recent: [String], suggestions: [String]) -> [ProjectChoice] {
        var seen: Set<String> = []
        let recentChoices = recent.filter { exists($0) && seen.insert($0).inserted }
            .map { ProjectChoice(url: URL(fileURLWithPath: $0, isDirectory: true), source: .recent) }
        let suggested = suggestions.reversed().filter { exists($0) && seen.insert($0).inserted }.prefix(suggestionLimit)
            .map { ProjectChoice(url: URL(fileURLWithPath: $0, isDirectory: true), source: .claudeCode) }
        return recentChoices + suggested
    }

    /// Touches the disk, so callers run it off the main actor.
    private static func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
