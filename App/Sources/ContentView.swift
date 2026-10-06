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
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
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

private struct SidebarView: View {
    @Bindable var model: SettingsModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Settings") {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: Self.symbols[category] ?? "slider.horizontal.3")
                        .badge(model.pendingCount(in: category))
                        .tag(SidebarItem.category(category))
                }
            }
            Section("More") {
                Label("Keybindings", systemImage: "keyboard")
                    .badge(model.keybindings.pending.count)
                    .tag(SidebarItem.keybindings)
                Label("Unverified", systemImage: "questionmark.diamond")
                    .tag(SidebarItem.unverified)
            }
        }
        .focused(isFocused)
        .safeAreaInset(edge: .bottom) {
            ClaudeStatusLine(status: model.claude)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private static let symbols: [String: String] = [
        "Interface": "macwindow",
        "Notifications": "bell",
        "Model and cost": "cpu",
        "Privacy": "hand.raised",
        "Safety": "lock.shield",
    ]
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
