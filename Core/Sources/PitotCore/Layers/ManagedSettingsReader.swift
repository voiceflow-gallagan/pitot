import Foundation

public struct ManagedSettings: Sendable, Equatable {
    /// The merged managed layer. Its `url` is the managed folder.
    public let layer: SettingsLayer
    /// Each file found, in merge order: `managed-settings.json` first, then the drop-in files.
    public let files: [SettingsLayer]
}

/// Reads the file-based managed settings. It only reads: Pitot never writes managed settings.
///
/// Rules, from https://code.claude.com/docs/en/managed-settings.md read 2026-10-06:
/// - "Claude Code merges `managed-settings.json` first, then every `*.json` file in the directory
///   in alphabetical order. ... Claude Code ignores hidden files and files that don't end in
///   `.json`." The files merge with the same rules as the layers (`SettingsMerge`).
/// - "An empty managed settings file counts as `{}`." An absent file is not a failure.
/// - A file that "isn't valid JSON, or its top level isn't an object" makes Claude Code refuse to
///   start, so the whole layer is `.invalid`.
/// - A file the system will not let Claude Code read means "every session starts without that
///   source's policies", so the whole layer is `.unreadable`.
/// - "A `null` removes the key". Nulls are removed from each file before the merge, on the
///   assumption that Claude Code checks each file on its own (inferred).
/// - "Alphabetical" is taken as a sort by UTF-16 code unit, so `B.json` comes before `a.json`.
///   It reads files and symbolic links and skips folders (inferred).
///
/// Server-managed settings and the macOS configuration profile are other managed sources and are
/// not read here.
public struct ManagedSettingsReader: Sendable {
    public static let defaultFolder = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true)
    public static let fileName = "managed-settings.json"
    public static let dropInFolderName = "managed-settings.d"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func load() -> SettingsLayer {
        read().layer
    }

    public func read() -> ManagedSettings {
        var names = [Self.fileName]
        switch dropInNames() {
        case .success(let dropIns):
            names += dropIns.map { "\(Self.dropInFolderName)/\($0)" }
        case .failure(let failure):
            let main = LayerLoader.load(id: .managed, url: folder.appendingPathComponent(Self.fileName))
            return ManagedSettings(layer: layer(.unreadable(failure.reason)), files: main.state == .missing ? [] : [main])
        }
        let files = names.map { (name: $0, layer: LayerLoader.load(id: .managed, url: folder.appendingPathComponent($0))) }
            .filter { $0.layer.state != .missing }
        return ManagedSettings(layer: merged(files), files: files.map(\.layer))
    }

    private func merged(_ files: [(name: String, layer: SettingsLayer)]) -> SettingsLayer {
        var documents: [JSONDocument] = []
        for file in files {
            switch file.layer.state {
            case .loaded(let document): documents.append(document)
            case .missing: continue
            case .invalid(let problem): return layer(.invalid(.managedFile(name: file.name, problem: problem)))
            case .unreadable(let reason): return layer(.unreadable(reason))
            }
        }
        if documents.isEmpty { return layer(.missing) }
        if documents.count == 1, let document = documents.first { return layer(.loaded(document)) }
        return layer(.loaded(JSONWriter.document(SettingsMerge.fold(documents.map { $0.decode($0.root) }))))
    }

    private func layer(_ state: SettingsLayer.State) -> SettingsLayer {
        SettingsLayer(id: .managed, url: folder, state: state)
    }

    private func dropInNames() -> Result<[String], ManagedReadFailure> {
        let directory = folder.appendingPathComponent(Self.dropInFolderName, isDirectory: true)
        let names: [String]
        do throws(SettingsFileError) {
            names = try POSIXFile.list(directory)
        } catch .io(_, let path, let code) {
            if code == ENOENT || code == ENOTDIR { return .success([]) }
            return .failure(ManagedReadFailure(reason: LayerFile.describe(code, at: path)))
        } catch {
            return .failure(ManagedReadFailure(reason: "\(directory.path): \(error)"))
        }
        return .success(
            names.filter { isDropIn($0, in: directory) }
                .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        )
    }

    private func isDropIn(_ name: String, in directory: URL) -> Bool {
        guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return false }
        var info = stat()
        guard lstat(directory.appendingPathComponent(name).path, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFLNK
    }
}

private struct ManagedReadFailure: Error {
    let reason: String
}
