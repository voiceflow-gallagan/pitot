import AppKit
import PitotCore
import SwiftUI

/// How one sidebar section looks: its symbol and tint. The symbol and the label carry the meaning,
/// so the tint is never the only cue.
struct SidebarStyle: Equatable {
    let symbol: String
    /// A system color, so it adapts to light, dark and Increase Contrast.
    let nsTint: NSColor
    /// The tint's name, so tests can check that no two sections share a tint.
    let tintName: String

    var tint: Color { Color(nsColor: nsTint) }
}

enum SidebarStyles {
    static let table: [SidebarItem: SidebarStyle] = [
        .category("Interface"): SidebarStyle(symbol: "macwindow", nsTint: .systemBlue, tintName: "blue"),
        .category("Notifications"): SidebarStyle(symbol: "bell.badge", nsTint: .systemPink, tintName: "pink"),
        .category("Model and cost"): SidebarStyle(symbol: "cpu", nsTint: .systemGreen, tintName: "green"),
        .category("Privacy"): SidebarStyle(symbol: "hand.raised", nsTint: .systemTeal, tintName: "teal"),
        .category("Safety"): SidebarStyle(symbol: "lock.shield", nsTint: .systemRed, tintName: "red"),
        .keybindings: SidebarStyle(symbol: "keyboard", nsTint: .systemIndigo, tintName: "indigo"),
        .unverified: SidebarStyle(symbol: "questionmark.diamond", nsTint: .systemGray, tintName: "gray"),
    ]

    /// For a category added to the catalog before it gets its own entry here.
    static let fallback = SidebarStyle(symbol: "slider.horizontal.3", nsTint: .systemBrown, tintName: "brown")

    static func style(for item: SidebarItem) -> SidebarStyle {
        table[item] ?? fallback
    }
}

/// The text color of a count badge: black or white, whichever reads better on the badge's tint.
/// System tints change with the appearance, so the choice is made for the appearance in use.
enum BadgeInk {
    static func color(on tint: NSColor, in appearance: NSAppearance) -> NSColor {
        contrast(.black, tint, in: appearance) >= contrast(.white, tint, in: appearance) ? .black : .white
    }

    /// The WCAG contrast ratio of two opaque colors, from 1 to 21.
    static func contrast(_ first: NSColor, _ second: NSColor, in appearance: NSAppearance) -> Double {
        let (a, b) = (luminance(first, in: appearance), luminance(second, in: appearance))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func appearance(dark: Bool, increasedContrast: Bool) -> NSAppearance? {
        let name: NSAppearance.Name =
            switch (dark, increasedContrast) {
            case (false, false): .aqua
            case (true, false): .darkAqua
            case (false, true): .accessibilityHighContrastAqua
            case (true, true): .accessibilityHighContrastDarkAqua
            }
        return NSAppearance(named: name)
    }

    private static func luminance(_ color: NSColor, in appearance: NSAppearance) -> Double {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let resolved else { return 0 }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.redComponent) + 0.7152 * linear(resolved.greenComponent) + 0.0722 * linear(resolved.blueComponent)
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

    /// Command-1 to Command-9 select the sidebar rows in order.
    var goToShortcuts: [GoToShortcut] {
        zip(sidebarItems, "123456789").map(GoToShortcut.init)
    }

    /// Moves the selection up or down the sidebar, stopping at either end.
    func selectAdjacent(_ offset: Int) {
        let items = sidebarItems
        guard let index = items.firstIndex(of: section) else { return }
        select(items[min(max(index + offset, 0), items.count - 1)])
    }
}
