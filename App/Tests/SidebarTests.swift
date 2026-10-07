import Foundation
import PitotCore
import Testing

@testable import Pitot

@MainActor
struct SidebarTests {
    @Test func everySectionHasItsOwnSymbolAndTint() async throws {
        let fixture = try await ModelFixture.make()
        let items = fixture.model.sidebarItems
        #expect(items.count == 7)
        #expect(Set(items).count == items.count)
        #expect(items.allSatisfy { SidebarStyles.table[$0] != nil })
        #expect(SidebarStyles.table.count == items.count)
        let styles = items.map(SidebarStyles.style(for:))
        #expect(Set(styles.map(\.tintName)).count == styles.count)
        #expect(Set(styles.map(\.symbol)).count == styles.count)
    }

    @Test func badgesCountCustomisedSettingsAcrossLayers() async throws {
        // `showThinkingSummaries: false` is the default value, written down, so it counts.
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        #expect(model.customisedCount(in: "Interface") == 1)
        #expect(model.customisedCount(in: "Model and cost") == 1)
        #expect(model.customisedCount(in: "Privacy") == 0)
        #expect(model.sidebarInfo(.category("Privacy")).badgeText == nil)

        let project = try fixture.makeProject(local: "{\n  \"tui\": \"fullscreen\",\n  \"env\": {\n    \"DISABLE_TELEMETRY\": \"1\"\n  }\n}\n")
        await model.selectProject(project)
        #expect(model.customisedCount(in: "Interface") == 2)
        #expect(model.customisedCount(in: "Privacy") == 1)
        #expect(model.sidebarInfo(.category("Interface")).badgeText == "2")
    }

    @Test func otherSectionsCountBindingsAndListedKeys() async throws {
        let file = """
            {"bindings": [{"context": "Chat", "bindings": {"ctrl+k": "chat:clearInput", "ctrl+y": null}}]}
            """
        let fixture = try await ModelFixture.make(keybindings: file)
        #expect(fixture.model.sidebarInfo(.keybindings).count == 2)
        #expect(fixture.model.sidebarInfo(.keybindings).accessibilityLabel == "Keybindings, 2 bindings")
        #expect(fixture.model.sidebarInfo(.unverified).accessibilityLabel == "Unverified, 15 keys listed")

        fixture.model.keybindings.request(.add(context: "Chat", key: "ctrl+j", action: "chat:clearScreen"))
        #expect(fixture.model.sidebarInfo(.keybindings).count == 2)
        #expect(fixture.model.sidebarInfo(.keybindings).hasPending)
    }

    @Test func badgeTextHidesZeroAndCapsAt99() {
        func info(_ count: Int) -> SidebarRowInfo {
            SidebarRowInfo(
                item: .unverified, name: "X", style: SidebarStyles.fallback, count: count, countNoun: ("thing", "things"), pending: 0)
        }
        #expect(info(0).badgeText == nil)
        #expect(info(7).badgeText == "7")
        #expect(info(99).badgeText == "99")
        #expect(info(100).badgeText == "99+")
        #expect(info(1).accessibilityLabel == "X, 1 thing")
    }

    @Test func pendingChangeShowsADotAndIsRead() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        #expect(!model.sidebarInfo(.category("Interface")).hasPending)
        #expect(model.sidebarInfo(.category("Interface")).accessibilityLabel == "Interface, 1 setting customised")

        model.requestChange("fullscreen", for: try fixture.tweak("tui"))
        let interface = model.sidebarInfo(.category("Interface"))
        #expect(interface.hasPending)
        #expect(interface.pending == model.pendingCount(in: "Interface"))
        #expect(interface.accessibilityLabel == "Interface, 1 setting customised, 1 pending change")
        #expect(!model.sidebarInfo(.category("Safety")).hasPending)
    }

    @Test func projectMenuHidesOnKeybindingsAndScopePickerShowsOnlyForSettings() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        var withMenu: [SidebarItem] = []
        var withPicker: [SidebarItem] = []
        for item in model.sidebarItems {
            model.select(item)
            if model.showsProjectMenu { withMenu.append(item) }
            if model.showsScopePicker { withPicker.append(item) }
        }
        let settings = model.categories.map(SidebarItem.category)
        #expect(settings.count == 5)
        #expect(withMenu == settings + [.unverified])
        #expect(withPicker == settings)
    }

    @Test func arrowsMoveTheSelectionWithinTheList() async throws {
        let fixture = try await ModelFixture.make()
        let model = fixture.model
        #expect(model.section == .category("Interface"))
        model.selectAdjacent(-1)
        #expect(model.section == .category("Interface"))
        model.selectAdjacent(1)
        #expect(model.section == .category("Notifications"))
        #expect(model.selectedCategory == "Notifications")

        model.select(.unverified)
        model.selectAdjacent(1)
        #expect(model.section == .unverified)
        model.selectAdjacent(-1)
        #expect(model.section == .keybindings)

        model.select(.category("Safety"))
        model.searchText = "telemetry"
        #expect(model.visibleSections.flatMap(\.tweaks).map(\.id).contains("DISABLE_TELEMETRY"))
    }
}
