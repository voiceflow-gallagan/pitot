/// One settings file in the stack Claude Code merges into the settings a session uses.
///
/// Precedence, highest first: managed, local, project, user. `allCases` lists the layers lowest
/// first, the order Claude Code merges them in. Local beating project is tested; the place of user
/// and managed comes from the docs (rule 16 in `Core/MERGE-RULES.md`).
///
/// The command-line layer, `claude --settings`, sits between managed and local, but it is not a
/// Pitot layer: it lasts only for the session that passed the flag, and Pitot cannot see which
/// running sessions used it. The UI can only mention it as a possible hidden override.
public enum LayerID: String, Sendable, Hashable, CaseIterable, Comparable {
    case user, project, local, managed

    public static let byPrecedence: [LayerID] = [.managed, .local, .project, .user]

    public init(_ kind: SettingsLayerKind) {
        switch kind {
        case .user: self = .user
        case .project: self = .project
        case .local: self = .local
        }
    }

    /// The file Pitot may write for this layer. Nil for managed settings, which Pitot only reads.
    public var writableKind: SettingsLayerKind? {
        switch self {
        case .user: .user
        case .project: .project
        case .local: .local
        case .managed: nil
        }
    }

    /// A layer with a higher rank wins over a lower one.
    public var rank: Int {
        switch self {
        case .user: 0
        case .project: 1
        case .local: 2
        case .managed: 3
        }
    }

    public static func < (lhs: LayerID, rhs: LayerID) -> Bool {
        lhs.rank < rhs.rank
    }
}
