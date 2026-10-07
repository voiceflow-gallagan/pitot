import PitotCore
import SwiftUI

/// How one sidebar section looks: its symbol and tint. The symbol and the label carry the meaning,
/// so the tint is never the only cue.
struct SidebarStyle: Equatable {
    let symbol: String
    let tint: Color
    /// The tint's name, so tests can check that no two sections share a tint.
    let tintName: String
}

enum SidebarStyles {
    static let table: [SidebarItem: SidebarStyle] = [
        .category("Interface"): SidebarStyle(symbol: "macwindow", tint: .blue, tintName: "blue"),
        .category("Notifications"): SidebarStyle(symbol: "bell.badge", tint: .pink, tintName: "pink"),
        .category("Model and cost"): SidebarStyle(symbol: "cpu", tint: .green, tintName: "green"),
        .category("Privacy"): SidebarStyle(symbol: "hand.raised", tint: .teal, tintName: "teal"),
        .category("Safety"): SidebarStyle(symbol: "lock.shield", tint: .red, tintName: "red"),
        .keybindings: SidebarStyle(symbol: "keyboard", tint: .indigo, tintName: "indigo"),
        .unverified: SidebarStyle(symbol: "questionmark.diamond", tint: .gray, tintName: "gray"),
    ]

    /// For a category added to the catalog before it gets its own entry here.
    static let fallback = SidebarStyle(symbol: "slider.horizontal.3", tint: .secondary, tintName: "secondary")

    static func style(for item: SidebarItem) -> SidebarStyle {
        table[item] ?? fallback
    }
}

/// Everything one sidebar row shows.
struct SidebarRowInfo: Equatable {
    let item: SidebarItem
    let name: String
    let style: SidebarStyle
    /// Customised settings, bindings in the file, or listed keys, depending on the section.
    let count: Int
    let countNoun: (singular: String, plural: String)
    let pending: Int

    static func == (lhs: SidebarRowInfo, rhs: SidebarRowInfo) -> Bool {
        lhs.item == rhs.item && lhs.name == rhs.name && lhs.style == rhs.style && lhs.count == rhs.count
            && lhs.countNoun == rhs.countNoun && lhs.pending == rhs.pending
    }

    /// Nil hides the badge. Large counts read 99+.
    var badgeText: String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    var hasPending: Bool { pending > 0 }

    /// Such as "Interface, 4 settings customised, 1 pending change".
    var accessibilityLabel: String {
        var parts = [name]
        if count > 0 { parts.append("\(count) \(count == 1 ? countNoun.singular : countNoun.plural)") }
        if pending > 0 { parts.append("\(pending) pending change\(pending == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

extension SettingsModel {
    /// The sidebar rows in order: the settings categories, then Keybindings and Unverified.
    var sidebarItems: [SidebarItem] {
        categories.map(SidebarItem.category) + [.keybindings, .unverified]
    }

    func sidebarInfo(_ item: SidebarItem) -> SidebarRowInfo {
        switch item {
        case .category(let category):
            SidebarRowInfo(
                item: item, name: category, style: SidebarStyles.style(for: item), count: customisedCount(in: category),
                countNoun: ("setting customised", "settings customised"), pending: pendingCount(in: category))
        case .keybindings:
            SidebarRowInfo(
                item: item, name: "Keybindings", style: SidebarStyles.style(for: item), count: keybindings.bindingCount,
                countNoun: ("binding", "bindings"), pending: keybindings.pending.count)
        case .unverified:
            SidebarRowInfo(
                item: item, name: "Unverified", style: SidebarStyles.style(for: item), count: unverified.keys.count,
                countNoun: ("key listed", "keys listed"), pending: 0)
        }
    }

    /// Settings of `category` that some layer sets, whatever the value, a written default included.
    func customisedCount(in category: String) -> Int {
        catalog.tweaks.filter { $0.category == category && effective.value(for: $0) != nil }.count
    }

    /// Moves the selection up or down the sidebar, stopping at either end.
    func selectAdjacent(_ offset: Int) {
        let items = sidebarItems
        guard let index = items.firstIndex(of: section) else { return }
        select(items[min(max(index + offset, 0), items.count - 1)])
    }
}
