import PitotCore
import Foundation

/// Key names Claude Code reads that the docs do not list, from `Catalog/unverified.json`. The file
/// holds names only. Pitot shows them read-only and never edits them.
///
/// Decoding is strict: an unknown key or a missing required field fails, so a typo in the
/// hand-written file shows an error instead of a silently wrong list.
struct UnverifiedCatalog: Sendable, Equatable, Decodable {
    let researchDate: String
    let claudeCodeVersionChecked: String
    let docsChecked: [String]
    let note: String
    let keys: [UnverifiedKey]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case researchDate, claudeCodeVersionChecked, docsChecked, note, keys
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownUnverifiedKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        researchDate = try container.decode(String.self, forKey: .researchDate)
        claudeCodeVersionChecked = try container.decode(String.self, forKey: .claudeCodeVersionChecked)
        docsChecked = try container.decode([String].self, forKey: .docsChecked)
        note = try container.decode(String.self, forKey: .note)
        keys = try container.decode([UnverifiedKey].self, forKey: .keys)
    }
}

struct UnverifiedKey: Sendable, Equatable, Identifiable, Decodable {
    enum Kind: String, Sendable, Decodable, CaseIterable {
        case setting, env
    }

    enum Status: String, Sendable, Decodable, CaseIterable {
        /// Seen in Claude Code or its public schema, but left out of the docs.
        case hidden
        case unverified
    }

    let name: String
    let kind: Kind
    let status: Status
    let seenIn: [String]
    /// Empty in the shipped file, which holds names only.
    let description: String
    let notes: String

    var id: String { "\(kind.rawValue):\(name)" }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, kind, status, seenIn, description, notes
    }

    init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownUnverifiedKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        status = try container.decode(Status.self, forKey: .status)
        seenIn = try container.decode([String].self, forKey: .seenIn)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// One row of the read-only list. It holds text only: there is nothing to edit.
struct UnverifiedRow: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let statusLabel: String
    let description: String
    let seenIn: String
    let notes: String
    /// "Present in your files: User, Project-local", or "Not found in your files".
    let presence: String
}

struct UnverifiedSection: Sendable, Equatable, Identifiable {
    let title: String
    let rows: [UnverifiedRow]

    var id: String { title }
}

enum UnverifiedList {
    static let header =
        "These key names are not in the official docs. Listing them is not an endorsement. They may change or disappear. "
        + "Pitot shows them read-only and never edits them."

    /// Sections by status, then kind, filtered by `search` on the name, description and notes.
    /// A setting counts as present when a layer has it at the top level, an env var when a layer's env block has it.
    static func sections(_ catalog: UnverifiedCatalog, layers: [SettingsLayer], search: String) -> [UnverifiedSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [UnverifiedSection] = []
        for status in UnverifiedKey.Status.allCases {
            for kind in UnverifiedKey.Kind.allCases {
                let rows = catalog.keys
                    .filter { $0.status == status && $0.kind == kind }
                    .filter { query.isEmpty || [$0.name, $0.description, $0.notes].contains { $0.localizedCaseInsensitiveContains(query) } }
                    .map { row(for: $0, layers: layers) }
                if !rows.isEmpty { sections.append(UnverifiedSection(title: title(status, kind), rows: rows)) }
            }
        }
        return sections
    }

    static func row(for key: UnverifiedKey, layers: [SettingsLayer]) -> UnverifiedRow {
        let path = key.kind == .env ? ["env", key.name] : [key.name]
        let found = LayerID.byPrecedence.filter { id in
            layers.first { $0.id == id }?.document?.node(at: path) != nil
        }
        return UnverifiedRow(
            id: key.id,
            name: key.name,
            statusLabel: key.status == .hidden ? "Not documented" : "Unverified",
            description: key.description.isEmpty ? "No description" : key.description,
            seenIn: key.seenIn.joined(separator: ", "),
            notes: key.notes,
            presence: found.isEmpty ? "Not found in your files" : "Present in your files: \(found.map(\.displayName).joined(separator: ", "))")
    }

    private static func title(_ status: UnverifiedKey.Status, _ kind: UnverifiedKey.Kind) -> String {
        let what = kind == .setting ? "settings" : "env vars"
        return status == .hidden ? "Not documented \(what)" : "Unverified \(what)"
    }
}

private struct UnverifiedCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    fileprivate func rejectUnknownUnverifiedKeys<Key: CodingKey & CaseIterable>(besides keys: Key.Type) throws {
        let known = Set(keys.allCases.map(\.stringValue))
        let container = try container(keyedBy: UnverifiedCodingKey.self)
        guard let first = container.allKeys.map(\.stringValue).filter({ !known.contains($0) }).min() else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [UnverifiedCodingKey(stringValue: first)], debugDescription: "Unknown key \"\(first)\""))
    }
}
