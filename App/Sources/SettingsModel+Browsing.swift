import PitotCore
import Foundation

struct TweakSection: Identifiable, Equatable {
    let category: String
    let tweaks: [Tweak]

    var id: String { category }
}

extension SettingsModel {
    /// The selected category, or every matching row grouped by category while searching.
    var visibleSections: [TweakSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? [selectedCategory ?? categories.first].compactMap { $0 } : categories
        return shown.compactMap { category in
            let tweaks = catalog.tweaks.filter { $0.category == category && (query.isEmpty || $0.matches(search: query)) }
            return tweaks.isEmpty ? nil : TweakSection(category: category, tweaks: tweaks)
        }
    }

    /// One message per layer Claude Code skips or Pitot cannot read, the managed layer included.
    var layerProblems: [String] {
        var problems = ([user] + [projectStores?.project, projectStores?.local].compactMap { $0 }).compactMap(\.problem)
        switch managed.state {
        case .invalid(let problem):
            problems.append(
                "The managed settings in \(services.managedFolder.path) are invalid (\(problem)). Claude Code refuses to start until they are fixed.")
        case .unreadable(let reason):
            problems.append("Pitot cannot read the managed settings: \(reason)")
        case .loaded, .missing:
            break
        }
        return problems
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Pending changes plus the auto-sets they pull in, for the sidebar badge.
    func pendingCount(in category: String) -> Int {
        let autoSetIds = Set(review.resolution?.autoSet.map(\.tweakId) ?? [])
        return catalog.tweaks.filter { $0.category == category && (pending[$0.id] != nil || autoSetIds.contains($0.id)) }.count
    }

    /// An empty field means the key is not set.
    func commitText(_ text: String, for tweak: Tweak) {
        requestChange(text.isEmpty ? nil : .string(text), for: tweak)
    }

    /// Text that is not a whole number is not committed; `validationMessage` explains why.
    func commitInteger(_ text: String, for tweak: Tweak) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            requestChange(nil, for: tweak)
        } else if let number = Int(trimmed) {
            requestChange(.integer(number), for: tweak)
        }
    }

    /// The problem with text typed into a string, path or integer field, or nil when it can be committed.
    func validationMessage(for tweak: Tweak, text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let value: TweakValue
        if case .integer = tweak.valueType {
            guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return "Enter a whole number." }
            value = .integer(number)
        } else {
            value = .string(text)
        }
        return Validator.check(tweak, value: value).first?.message
    }
}

extension SettingsModel {
    var section: SidebarItem {
        sidebarSelection ?? selectedCategory.map(SidebarItem.category) ?? .keybindings
    }

    func select(_ item: SidebarItem) {
        sidebarSelection = item
    }

    /// Keybindings always edit the user file, so the project menu hides there. The unverified list
    /// keeps it, because the chosen project changes which files it searches.
    var showsProjectMenu: Bool {
        section != .keybindings
    }

    /// The scope picker chooses the settings file that edits go to, so only settings sections show it.
    var showsScopePicker: Bool {
        if case .category = section { return true }
        return false
    }

    var unverifiedSections: [UnverifiedSection] {
        UnverifiedList.sections(unverified, layers: effective.layers, search: searchText)
    }

    // MARK: Undo in the selected section

    var undoTargetName: String {
        section == .keybindings ? "Keybindings" : scope.displayName
    }

    var canUndoInSection: Bool {
        section == .keybindings ? keybindings.canUndo : canUndo
    }

    var isWritingInSection: Bool {
        section == .keybindings ? keybindings.isWriting : isWriting
    }

    var blockedUndoInSection: [[String]]? {
        section == .keybindings ? keybindings.blockedUndo : blockedUndo
    }

    /// Undoes the newest group of the keybindings file or of the selected settings layer.
    func undoInSection(force: Bool = false) async {
        if section == .keybindings {
            await keybindings.undo(force: force)
        } else {
            await undo(force: force)
        }
    }

    func dismissBlockedUndoInSection() {
        if section == .keybindings {
            keybindings.dismissBlockedUndo()
        } else {
            dismissBlockedUndo()
        }
    }
}
