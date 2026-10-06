import PitotCore

/// One change the user asked for in `keybindings.json`, waiting for Apply.
enum KeybindingEdit: Sendable, Equatable, Identifiable {
    case add(context: String, key: String, action: String)
    case change(context: String, key: String, action: String)
    /// Sets the key to `null`, which turns off a default shortcut.
    case unbind(context: String, key: String)
    case remove(context: String, key: String)

    var id: String { "\(context)|\(key)|\(summary)" }

    var context: String {
        switch self {
        case .add(let context, _, _), .change(let context, _, _), .unbind(let context, _), .remove(let context, _): context
        }
    }

    var key: String {
        switch self {
        case .add(_, let key, _), .change(_, let key, _), .unbind(_, let key), .remove(_, let key): key
        }
    }

    /// The line the review panel and the history show, such as "Chat ctrl+k: app:redraw".
    var summary: String {
        switch self {
        case .add(let context, let key, let action): "Add \(context) \(key): \(action)"
        case .change(let context, let key, let action): "Change \(context) \(key) to \(action)"
        case .unbind(let context, let key): "Unbind \(context) \(key) (null)"
        case .remove(let context, let key): "Remove \(context) \(key)"
        }
    }

    func plan(with editor: KeybindingsEditor) -> KeybindingsEditor.Plan {
        switch self {
        case .add(let context, let key, let action): editor.addBinding(context: context, key: key, action: action)
        case .change(let context, let key, let action): editor.changeAction(context: context, key: key, newAction: action)
        case .unbind(let context, let key): editor.unbind(context: context, key: key)
        case .remove(let context, let key): editor.removeBinding(context: context, key: key)
        }
    }
}

extension KeybindingsEditor.Plan {
    /// Errors, plus reserved keys: the validator only warns about them because Claude Code reads the
    /// file anyway, but it never lets such a key be rebound, so Pitot does not write one.
    var blockingIssues: [KeybindingsValidator.Issue] {
        issues.filter { $0.severity == .error || $0.kind == .reservedKey }
    }

    var isRefused: Bool { !blockingIssues.isEmpty || operations.isEmpty }
}
