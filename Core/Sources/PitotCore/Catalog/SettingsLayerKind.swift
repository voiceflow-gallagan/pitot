/// A settings file Pitot can write: `~/.claude/settings.json`, a project's shared
/// `.claude/settings.json`, or its `.claude/settings.local.json`.
public enum SettingsLayerKind: String, Codable, Sendable, CaseIterable {
    case user, project, local
}
