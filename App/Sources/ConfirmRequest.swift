import PitotCore
import Foundation

/// A question the user must answer before Pitot goes ahead.
struct ConfirmRequest: Identifiable, Equatable {
    enum Action: Equatable {
        /// Add this value to the pending changes.
        case change(tweakId: String, value: TweakValue?)
        /// Write the pending changes to the project's shared settings file.
        case writeSharedProject
    }

    let id: String
    let headline: String
    let message: String
    /// The key or file the request is about.
    let detail: String
    let action: Action

    static func change(_ tweak: Tweak, value: TweakValue?, message: String) -> ConfirmRequest {
        ConfirmRequest(
            id: tweak.id, headline: "\(tweak.title): set to \(tweak.label(for: value))", message: message, detail: tweak.keyText,
            action: .change(tweakId: tweak.id, value: value))
    }

    static func sharedProjectWrite(_ file: URL) -> ConfirmRequest {
        ConfirmRequest(
            id: "shared-project", headline: "Write to the shared project settings?",
            message: "This file is usually committed to git and shared with your team.", detail: file.path, action: .writeSharedProject)
    }

    var tweakId: String? {
        if case .change(let id, _) = action { return id }
        return nil
    }

    var value: TweakValue? {
        if case .change(_, let value) = action { return value }
        return nil
    }
}
