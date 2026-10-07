import AppKit
import SwiftUI

/// The project's web pages. A fork changes them here.
enum ProjectLinks {
    struct Link: Equatable {
        let title: String
        let address: String

        var url: URL? { URL(string: address) }
    }

    static let repository = "https://github.com/voiceflow-gallagan/pitot"
    static let securityReport = "https://github.com/voiceflow-gallagan/pitot/security/advisories/new"
    static let releaseNotes = "https://github.com/voiceflow-gallagan/pitot/releases"

    /// The Help menu, in order.
    static let helpItems = [
        Link(title: "Pitot on GitHub", address: repository),
        Link(title: "Report a Security Issue", address: securityReport),
        Link(title: "Release Notes", address: releaseNotes),
    ]
}

/// Which menu commands can run now. The menus and their keys follow these rules.
struct CommandAvailability: Equatable {
    static let undoLastChangeTitle = "Undo Last Change"

    /// "Undo" while a text field has focus, where Command-Z undoes typing.
    var undoTitle = undoLastChangeTitle
    var undo = false
    /// True when Undo and Redo go to the focused text field instead of the applied changes.
    var undoActsOnText = false
    var redo = false
    var apply = false
    var discard = false
    var chooseProject = false
    var runSetupQuestions = false
    var goToSection = false
    var find = false

    /// While a sheet is open, only text undo works. Apply and Discard wait while a text field has focus,
    /// so its draft is not left out and Command-Delete still deletes text there.
    @MainActor
    static func make(model: SettingsModel?, isEditingText: Bool, hasSheet: Bool) -> CommandAvailability {
        var available = CommandAvailability()
        if isEditingText {
            available.undoTitle = "Undo"
            available.undo = true
            available.undoActsOnText = true
            available.redo = true
        }
        guard let model, !hasSheet else { return available }
        if !isEditingText {
            available.undo = model.canUndoInSection && !model.isWritingInSection
            available.apply = model.canApplyInSection
            available.discard = model.canDiscardInSection
        }
        available.chooseProject = model.showsProjectMenu && !model.isWriting
        available.runSetupQuestions = model.canRunSetupQuestions
        available.goToSection = true
        available.find = true
        return available
    }
}

/// The menu bar. Every item works on the main window's model, once it is loaded.
struct PitotCommands: Commands {
    let model: SettingsModel?
    let window: WindowState
    let updates: UpdatesModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AppMenuItems(updates: updates)
        }
        CommandGroup(replacing: .newItem) {
            FileMenuItems(model: model, window: window)
        }
        CommandGroup(replacing: .undoRedo) {
            UndoMenuItems(model: model, window: window)
        }
        CommandGroup(after: .pasteboard) {
            FindMenuItem(model: model, window: window)
        }
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) {
            GoToMenuItems(model: model, window: window)
        }
        CommandGroup(replacing: .help) {
            ForEach(ProjectLinks.helpItems, id: \.title) { link in
                if let url = link.url {
                    Link(link.title, destination: url)
                }
            }
        }
    }
}

private struct FindMenuItem: View {
    let model: SettingsModel?
    let window: WindowState

    var body: some View {
        let available = CommandAvailability.make(model: model, isEditingText: window.isEditingText, hasSheet: window.hasSheet)
        Divider()
        Button("Find") { window.focusSearchField() }
            .keyboardShortcut("f")
            .disabled(!available.find)
    }
}

private struct FileMenuItems: View {
    let model: SettingsModel?
    let window: WindowState

    var body: some View {
        let available = CommandAvailability.make(model: model, isEditingText: window.isEditingText, hasSheet: window.hasSheet)
        Button("Choose Project Folder…") {
            guard let model, let folder = ProjectPanel.chooseFolder() else { return }
            Task { await model.selectProject(folder) }
        }
        .keyboardShortcut("o")
        .disabled(!available.chooseProject)
        Button("Run Setup Questions…") { model?.startOnboarding() }
            .disabled(!available.runSetupQuestions)
        Divider()
        Button("Apply Changes") {
            guard let model else { return }
            Task { await model.applyInSection() }
        }
        .keyboardShortcut(.return)
        .disabled(!available.apply)
        Button("Discard Changes") { model?.discardInSection() }
            .keyboardShortcut(.delete)
            .disabled(!available.discard)
    }
}

private struct UndoMenuItems: View {
    let model: SettingsModel?
    let window: WindowState

    var body: some View {
        let available = CommandAvailability.make(model: model, isEditingText: window.isEditingText, hasSheet: window.hasSheet)
        Button(available.undoTitle) {
            if available.undoActsOnText {
                window.undoText()
            } else if let model {
                Task { await model.undoInSection() }
            }
        }
        .keyboardShortcut("z")
        .disabled(!available.undo)
        Button("Redo") { window.redoText() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!available.redo)
    }
}

private struct GoToMenuItems: View {
    let model: SettingsModel?
    let window: WindowState

    var body: some View {
        if let model {
            let available = CommandAvailability.make(model: model, isEditingText: window.isEditingText, hasSheet: window.hasSheet)
            Divider()
            ForEach(model.goToShortcuts, id: \.key) { shortcut in
                Button(model.sidebarInfo(shortcut.item).name) { model.select(shortcut.item) }
                    .keyboardShortcut(KeyEquivalent(shortcut.key))
                    .disabled(!available.goToSection)
            }
        }
    }
}

/// What the menus need to know about the windows: whether a text field has focus, and whether
/// the main window shows a sheet. AppKit updates every window after each event, so both are read then.
@MainActor
@Observable
final class WindowState {
    private(set) var isEditingText = false
    private(set) var hasSheet = false
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        mainWindow = window
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    private func update() {
        let editing = (NSApp.keyWindow ?? mainWindow)?.firstResponder is NSText
        let sheet = mainWindow?.attachedSheet != nil
        if editing != isEditingText { isEditingText = editing }
        if sheet != hasSheet { hasSheet = sheet }
    }

    /// Puts the cursor in the sidebar's search field.
    func focusSearchField() {
        guard let window = mainWindow, let field = Self.searchField(in: window.contentView?.superview ?? window.contentView) else { return }
        window.makeFirstResponder(field)
    }

    /// The focused text field's own undo, as the standard Edit menu would do it.
    func undoText() {
        guard let manager = textUndoManager, manager.canUndo else { return }
        manager.undo()
    }

    func redoText() {
        guard let manager = textUndoManager, manager.canRedo else { return }
        manager.redo()
    }

    private var textUndoManager: UndoManager? {
        (NSApp.keyWindow ?? mainWindow)?.firstResponder?.undoManager
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}

/// Hands the hosting window to `WindowState`.
struct WindowReader: NSViewRepresentable {
    let state: WindowState

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(state: state)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let state: WindowState

        init(state: WindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { state.attach(window) }
        }
    }
}
