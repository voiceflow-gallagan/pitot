import SwiftUI

/// One sidebar row: a tinted tile with a symbol, the section name, a count badge and a pending dot.
struct SidebarRow: View {
    let info: SidebarRowInfo
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SidebarTile(info: info, isSelected: isSelected)
                Text(info.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(info.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarTile: View {
    let info: SidebarRowInfo
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        Image(systemName: info.style.symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : info.style.tint)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : info.style.tint.opacity(increased ? 0.3 : 0.16)))
            .overlay {
                if increased {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Color.white : info.style.tint)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge = info.badgeText {
                    // On the selected row the badge turns white with black text, so it stays apart from
                    // the accent fill and reads whatever the accent color is.
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.black : badgeInk)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(isSelected ? Color.white : info.style.tint))
                        .overlay(Capsule().strokeBorder(ring, lineWidth: 1.5))
                        .fixedSize()
                        .offset(x: 9, y: -6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if info.hasPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(ring, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    private var badgeInk: Color {
        guard let appearance = BadgeInk.appearance(dark: colorScheme == .dark, increasedContrast: contrast == .increased) else { return .black }
        return Color(nsColor: BadgeInk.color(on: info.style.nsTint, in: appearance))
    }

    /// The ring around the badge and the dot matches what is behind the tile.
    private var ring: Color {
        isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor)
    }
}
