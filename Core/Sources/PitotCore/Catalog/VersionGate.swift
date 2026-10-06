public enum VersionStatus: Sendable, Equatable {
    case available
    /// The installed Claude Code is older than the tweak's minimum version.
    case needs(String)
    /// The tweak has a minimum version but the installed version is not known.
    case unknown
}

public enum VersionGate {
    public static func status(_ tweak: Tweak, installed: ClaudeVersion?) -> VersionStatus {
        guard let minVersion = tweak.minVersion else { return .available }
        guard let installed, let required = ClaudeVersion(exactly: minVersion) else { return .unknown }
        return installed < required ? .needs(minVersion) : .available
    }
}

extension ClaudeVersion {
    /// Parses text that is exactly a version, such as `2.1.257` or `2.1.257-beta.1`, and nothing else.
    init?(exactly text: String) {
        guard let version = ClaudeVersion(parsing: text), version.description == text else { return nil }
        self = version
    }
}
