import Foundation

/// Why a settings file adds nothing to the merged settings.
public indirect enum LayerProblem: Error, Sendable, Equatable, CustomStringConvertible {
    case syntax(JSONScanError)
    case notAnObject
    /// A `null` that is not the value of an `env` variable. Tested on Claude Code 2.1.291 for a
    /// top-level key and an object: the schema rejects the file and Claude Code ignores all of it.
    /// A `null` deeper down or on an unknown key is treated the same way (inferred).
    case nullValue(path: [String])
    /// One file of the managed folder has `problem`. Claude Code refuses to start until it is fixed.
    case managedFile(name: String, problem: LayerProblem)

    public var description: String {
        switch self {
        case .syntax(let error): "invalid JSON (\(error))"
        case .notAnObject: "the top level is not a JSON object"
        case .nullValue(let path): "null value makes Claude Code ignore the file (at \(path.joined(separator: ".")))"
        case .managedFile(let name, let problem): "\(name): \(problem)"
        }
    }
}

public struct SettingsLayer: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case loaded(JSONDocument)
        /// No file. This is normal: installing Claude Code creates no settings file.
        case missing
        /// The file adds nothing. Claude Code skips a user, project or local file it cannot parse or
        /// validate, and refuses to start on a managed file that is not a JSON object.
        case invalid(LayerProblem)
        /// The file exists but cannot be read, such as a permission error. The text names the cause.
        case unreadable(String)
    }

    public let id: LayerID
    /// The file, or for managed settings the folder that holds them. Nil for content given inline.
    public let url: URL?
    public let state: State

    public init(id: LayerID, url: URL?, state: State) {
        self.id = id
        self.url = url
        self.state = state
    }

    public var document: JSONDocument? {
        if case .loaded(let document) = state { return document }
        return nil
    }
}

public enum LayerLoader {
    /// Reads one settings file through `JSONScanner`. It never throws: a missing file is `.missing`,
    /// bad content is `.invalid`, and a read error is `.unreadable`.
    public static func load(id: LayerID, url: URL) -> SettingsLayer {
        switch LayerFile.read(url) {
        case .bytes(let bytes): layer(id: id, url: url, bytes: bytes)
        case .missing: SettingsLayer(id: id, url: url, state: .missing)
        case .unreadable(let reason): SettingsLayer(id: id, url: url, state: .unreadable(reason))
        }
    }

    /// The layer for file content already in memory.
    ///
    /// Whitespace only counts as `{}`, as the managed-settings docs state, and Pitot assumes the same
    /// for every settings file. In a managed file a `null` removes its key instead of the whole
    /// file: "A `null` removes the key" (managed-settings.md, "Keys that fail closed").
    public static func layer(id: LayerID, url: URL?, bytes: [UInt8]) -> SettingsLayer {
        switch LayerContent.parse(bytes, for: id) {
        case .success(let document): SettingsLayer(id: id, url: url, state: .loaded(document))
        case .failure(let problem): SettingsLayer(id: id, url: url, state: .invalid(problem))
        }
    }
}

enum LayerContent {
    static func parse(_ bytes: [UInt8], for layer: LayerID) -> Result<JSONDocument, LayerProblem> {
        let document: JSONDocument
        do throws(JSONScanError) {
            document = try JSONScanner.scan(bytes)
        } catch .emptyInput {
            return .success(JSONWriter.document(.object([])))
        } catch {
            return .failure(.syntax(error))
        }
        let root = document.decode(document.root)
        return normalized(root, for: layer).map { $0 == root ? document : JSONWriter.document($0) }
    }

    /// The content Claude Code reads from a layer, or the problem that makes it skip the file.
    static func normalized(_ root: JSONValue, for layer: LayerID) -> Result<JSONValue, LayerProblem> {
        guard case .object = root else { return .failure(.notAnObject) }
        if layer == .managed { return .success(SettingsTree.removingNulls(from: root)) }
        if let path = SettingsTree.firstNull(in: root) { return .failure(.nullValue(path: path)) }
        return .success(root)
    }
}

enum LayerFile {
    enum Read {
        case bytes([UInt8])
        case missing
        case unreadable(String)
    }

    static func read(_ url: URL) -> Read {
        do throws(SettingsFileError) {
            return .bytes(try POSIXFile.read(url))
        } catch .missingFile {
            return .missing
        } catch .io(_, let path, let code) {
            return code == ENOTDIR ? .missing : .unreadable(describe(code, at: path))
        } catch {
            return .unreadable("\(url.path): \(error)")
        }
    }

    static func describe(_ code: Int32, at path: String) -> String {
        "\(path): \(String(cString: strerror(code)))"
    }
}
