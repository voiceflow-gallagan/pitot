import PitotCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: SettingsModel
    @State private var showsInspector = true
    /// Keyboard focus starts in the category list. Without this, the first text field takes it, and
    /// typing meant for another window could end up in a setting.
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, isFocused: $isSidebarFocused)
                .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 300)
        } detail: {
            Group {
                switch model.section {
                case .category: DetailView(model: model)
                case .keybindings: KeybindingsView(model: model)
                case .unverified: UnverifiedView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 560)
                .inspector(isPresented: $showsInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 290, ideal: 320, max: 560)
                }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: searchPrompt)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                ScopeControls(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Run Setup Questions", systemImage: "wand.and.stars") { model.startOnboarding() }
                    .disabled(model.user.snapshot == nil || model.isWriting)
                    .help("Answer seven questions and review the suggested changes")
                Button("Undo Last Change", systemImage: "arrow.uturn.backward") { Task { await model.undoInSection() } }
                    .disabled(!model.canUndoInSection || model.isWritingInSection)
                    .help("Undo the last applied group in \(model.undoTargetName)")
                    .accessibilityLabel("Undo the last applied group in \(model.undoTargetName)")
                Button("Review and History", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help(showsInspector ? "Hide review and history" : "Show review and history")
                    .accessibilityLabel(showsInspector ? "Hide review and history" : "Show review and history")
            }
        }
        .sheet(item: $model.confirmRequest) { request in
            ConfirmSheet(request: request, onConfirm: { Task { await model.confirmChange() } }, onCancel: model.cancelConfirm)
        }
        .sheet(item: $model.onboarding, onDismiss: model.finishOnboarding) { onboarding in
            OnboardingSheet(onboarding: onboarding, settings: model)
        }
        .onChange(of: model.hasPending || model.keybindings.hasPending) { _, hasPending in
            if hasPending { showsInspector = true }
        }
        .frame(minHeight: 560)
        .defaultFocus($isSidebarFocused, true)
        .task {
            isSidebarFocused = true
            await model.start()
        }
        .onDisappear { model.stop() }
    }

    private var searchPrompt: String {
        switch model.section {
        case .category: "Search settings"
        case .keybindings: "Search keybindings"
        case .unverified: "Search unverified keys"
        }
    }
}

/// The section list: a tile per section with its own tint, a count badge and a pending dot.
///
/// Rows are buttons rather than list selection, so the selected row can carry the accent fill in
/// active and inactive windows alike. Up and down arrows move the selection, as in a list.
private struct SidebarView: View {
    @Bindable var model: SettingsModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        List {
            Section("Settings") {
                ForEach(model.categories, id: \.self) { category in
                    row(.category(category))
                }
            }
            Section("More") {
                row(.keybindings)
                row(.unverified)
            }
        }
        .listStyle(.sidebar)
        .focused(isFocused)
        .onKeyPress(.upArrow) {
            model.selectAdjacent(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.selectAdjacent(1)
            return .handled
        }
        .safeAreaInset(edge: .bottom) {
            ClaudeStatusLine(status: model.claude)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        SidebarRow(info: model.sidebarInfo(item), isSelected: model.section == item) { model.select(item) }
            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }
}

private struct DetailView: View {
    let model: SettingsModel

    var body: some View {
        let sections = model.visibleSections
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                FileLabel(model: model)
                Banners(model: model)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    ForEach(sections) { section in
                        Section(section.category) {
                            ForEach(section.tweaks) { tweak in
                                TweakRowView(model: model, tweak: tweak)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(model.isSearching ? "Search" : model.selectedCategory ?? "Pitot")
    }
}

private struct InspectorView: View {
    let model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.section == .keybindings {
                    KeybindingsReviewPanel(model: model.keybindings)
                } else {
                    ReviewPanel(model: model)
                }
                Divider()
                HistoryPanel(model: model)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
