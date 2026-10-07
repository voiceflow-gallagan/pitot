import PitotCore
import SwiftUI

/// How the file label looks for one scope and file mode.
struct FileLabelStyle: Equatable {
    let title: String
    let symbol: String
    let color: Color
    /// The full path under the title, or nil when the title already names the file.
    let path: String?
    let note: String?

    static let realFileNote = "Pitot backs up the file before every change. Undo is in the History panel."

    /// A real file in a release build is the normal case, so its label is calm. A debug build keeps
    /// the red label, so a developer notices that the real file is open.
    static func make(scope: SettingsLayerKind, mode: FileMode, project: String, url: URL, isDebugBuild: Bool) -> FileLabelStyle {
        func style(_ title: String, _ symbol: String, _ color: Color) -> FileLabelStyle {
            FileLabelStyle(title: title, symbol: symbol, color: color, path: url.path, note: nil)
        }
        switch (scope, mode) {
        case (.project, _): return style("Project settings, shared · \(project)", "person.2", .orange)
        case (.local, _): return style("Project-local settings · \(project)", "person", .green)
        case (.user, .copy): return style("Working on a COPY", "doc.on.doc", .yellow)
        case (.user, .real) where isDebugBuild: return style("REAL FILE", "exclamationmark.triangle.fill", .red)
        case (.user, .real):
            return FileLabelStyle(
                title: "Editing \((url.path as NSString).abbreviatingWithTildeInPath)", symbol: "doc.text", color: .gray,
                path: nil, note: realFileNote)
        case (.user, .custom): return style("Custom settings path", "doc.text", .blue)
        }
    }
}

extension FileMode {
    func keybindingsTitle(isDebugBuild: Bool) -> String {
        switch self {
        case .copy: "Keybindings · working on a COPY"
        case .real: isDebugBuild ? "Keybindings · REAL FILE" : "Keybindings"
        case .custom: "Keybindings · custom path"
        }
    }
}

/// The label that says which file Pitot edits: its own colour per mode for the user file,
/// and the full path for a project's shared or local file.
struct FileLabel: View {
    let model: SettingsModel

    var body: some View {
        let style = FileLabelStyle.make(
            scope: model.scope, mode: model.mode, project: model.projectFolder?.lastPathComponent ?? "",
            url: model.selectedStore?.url ?? model.settingsURL, isDebugBuild: LaunchConfiguration.isDebugBuild)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol).foregroundStyle(style.color).accessibilityHidden(true)
                Text(style.title).font(.headline)
                Spacer(minLength: 0)
            }
            if let path = style.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let note = style.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if model.selectedStore?.isMissing == true, model.selectedStore?.isEditable == true {
                Text("The file does not exist yet. Pitot creates it on the first Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(style.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.color.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

struct Banners: View {
    let model: SettingsModel

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if model.scope != .user {
                Text("Claude Code ignores permission rules in project files until you trust the folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Banner(symbol: "xmark.octagon.fill", color: .red, text: message) { model.errorMessage = nil }
            }
            ForEach(model.layerProblems, id: \.self) { problem in
                Banner(symbol: "exclamationmark.octagon", color: .red, text: problem, dismiss: nil)
            }
            if model.scope == .local, model.localNotIgnored {
                Banner(
                    symbol: "exclamationmark.triangle", color: .orange,
                    text: "Git does not ignore settings.local.json in this project, so it may be committed. Add it to .gitignore.",
                    dismiss: nil)
            }
            if model.externalChangeBanner {
                Banner(symbol: "arrow.triangle.2.circlepath", color: .blue, text: "Edited outside Pitot \u{2014} reloaded") {
                    model.externalChangeBanner = false
                }
            }
            if model.rebasedNotice {
                Text("The file changed while you were reviewing. Your changes were applied to the newer content.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Banner: View {
    let symbol: String
    let color: Color
    let text: String
    /// Nil for a banner that stays until its cause is fixed.
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss message")
            }
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ClaudeStatusLine: View {
    let status: ClaudeStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption)
                if case .found(let installation) = status {
                    Text(installation.executable.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .checking: "Looking for Claude Code..."
        case .found(let installation): "Claude Code \(installation.version.description)"
        case .notFound: "Claude Code not found"
        }
    }

    private var symbol: String {
        switch status {
        case .checking: "hourglass"
        case .found: "terminal"
        case .notFound: "questionmark.circle"
        }
    }
}

extension Tweak.Risk {
    var badge: (label: String, symbol: String, color: Color) {
        switch self {
        case .security: ("Security", "lock.shield", .red)
        case .cost: ("Cost", "dollarsign.circle", .orange)
        case .behavior: ("Behavior", "gearshape", .purple)
        case .privacy: ("Privacy", "hand.raised", .blue)
        }
    }
}

struct RiskBadges: View {
    let risks: Set<Tweak.Risk>

    var body: some View {
        ForEach(Tweak.Risk.allCases.filter(risks.contains), id: \.self) { risk in
            let badge = risk.badge
            Tag(text: badge.label, symbol: badge.symbol, color: badge.color)
                .accessibilityLabel("\(badge.label) risk")
        }
    }
}

/// A small capsule label, used for risk badges and the pending marker.
struct Tag: View {
    let text: String
    var symbol: String?
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}

struct CatalogErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Pitot cannot load its tweak catalog", systemImage: "exclamationmark.triangle")
        } description: {
            ScrollView {
                Text(message)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }
}
