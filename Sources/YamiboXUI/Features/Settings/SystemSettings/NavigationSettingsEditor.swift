import SwiftUI
import YamiboXCore

struct NavigationSettingsEditor: View {
    let initial: AppNavigationSettings
    let save: (AppNavigationSettings) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var draft: AppNavigationSettings
    @State private var isSaving = false
    @State private var confirmsDiscard = false
    @State private var confirmsReset = false
    @State private var errorMessage: String?
    @State private var startupChanged = false

    init(initial: AppNavigationSettings, save: @escaping (AppNavigationSettings) async throws -> Void) {
        self.initial = initial
        self.save = save
        _draft = State(initialValue: initial)
    }

    private var hasChanges: Bool { draft != initial }

    var body: some View {
        NavigationStack {
            List {
                NavigationPreviewSection(configuration: draft, showsFallbackNotice: startupChanged) { tab in
                    draft = AppNavigationSettings(tabs: draft.tabs, startupTab: tab)
                    startupChanged = false
                }
                NavigationSelectedSection(
                    tabs: draft.tabs,
                    remove: remove,
                    move: move,
                    reorder: { indices, destination in
                        var tabs = draft.tabs
                        tabs.move(fromOffsets: indices, toOffset: destination)
                        update(tabs: tabs)
                    }
                )
                // Recreate editing cells when membership changes: a cell moved
                // from the available section otherwise retains non-movable traits.
                // Reordering alone preserves identity and the active drag.
                .id(Set(draft.tabs))
                NavigationAvailableSection(tabs: draft.tabs) { tab in
                    guard draft.tabs.count < 5 else { return }
                    update(tabs: draft.tabs + [tab])
                }
                NavigationResetSection {
                    confirmsReset = true
                }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(isSaving)
            .navigationTitle(L10n.string("settings.navigation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) {
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            do { try await save(draft); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.string("common.save")).fontWeight(.semibold) }
                    }
                    .disabled(!hasChanges || isSaving)
                }
            }
        }
        .tint(theme.controlAccent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasChanges || isSaving)
        .confirmationDialog(L10n.string("settings.navigation.discard_title"), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(L10n.string("settings.navigation.discard"), role: .destructive) { dismiss() }
            Button(L10n.string("settings.navigation.continue_editing"), role: .cancel) {}
        }
        .confirmationDialog(L10n.string("settings.navigation.reset_title"), isPresented: $confirmsReset, titleVisibility: .visible) {
            Button(L10n.string("settings.navigation.reset")) { draft = AppNavigationSettings(); startupChanged = false }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("settings.navigation.reset_message"))
        }
        .alert(L10n.string("settings.navigation.save_failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.string("common.ok"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func update(tabs: [AppTab]) {
        let oldStartup = draft.startupTab
        draft = AppNavigationSettings(tabs: tabs, startupTab: oldStartup)
        if oldStartup != draft.startupTab { startupChanged = true }
    }

    private func remove(_ tab: AppTab) {
        guard !tab.isRequired else { return }
        update(tabs: draft.tabs.filter { $0 != tab })
    }

    private func move(_ tab: AppTab, by offset: Int) {
        guard let index = draft.tabs.firstIndex(of: tab), draft.tabs.indices.contains(index + offset) else { return }
        var tabs = draft.tabs
        tabs.swapAt(index, index + offset)
        update(tabs: tabs)
    }
}

private struct NavigationPreviewSection: View {
    let configuration: AppNavigationSettings
    let showsFallbackNotice: Bool
    let select: (AppTab) -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("settings.navigation.preview_format", configuration.startupTab.title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    NavigationBarPreview(configuration: configuration, select: select)
                    ScrollView(.horizontal) {
                        NavigationBarPreview(configuration: configuration, select: select)
                    }.scrollIndicators(.hidden)
                }
            }
            .padding(.vertical, 8)
        } footer: {
            Text(L10n.string("settings.navigation.preview_hint"))
            if showsFallbackNotice {
                Text(L10n.string("settings.navigation.startup_fallback_format", configuration.startupTab.title))
            }
        }
        .listSectionSeparator(.hidden)
    }
}

private struct NavigationBarPreview: View {
    let configuration: AppNavigationSettings
    let select: (AppTab) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(configuration.tabs) { tab in
                Button {
                    select(tab)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: tab.systemImage).font(.title3)
                        Text(tab.title).font(.caption).fixedSize()
                    }
                    .foregroundStyle(tab == configuration.startupTab ? theme.controlAccent : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityHint(L10n.string("settings.navigation.select_startup"))
                .accessibilityAddTraits(tab == configuration.startupTab ? .isSelected : [])
            }
        }
        .padding(.vertical, 12)
    }
}

private struct NavigationSelectedSection: View {
    let tabs: [AppTab]
    let remove: (AppTab) -> Void
    let move: (AppTab, Int) -> Void
    let reorder: (IndexSet, Int) -> Void

    var body: some View {
        Section {
            ForEach(tabs) { tab in
                HStack(spacing: 12) {
                    if !tab.isRequired {
                        Button { remove(tab) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.string("settings.navigation.remove_format", tab.title))
                    }
                    Label(tab.title, systemImage: tab.systemImage)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 44)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(tab == tabs.last ? .hidden : .visible, edges: .bottom)
                .accessibilityAction(named: Text(L10n.string("settings.navigation.move_up"))) { move(tab, -1) }
                .accessibilityAction(named: Text(L10n.string("settings.navigation.move_down"))) { move(tab, 1) }
            }
            .onMove(perform: reorder)
        } header: {
            Text(L10n.string("settings.navigation.selected_count_format", tabs.count))
        } footer: {
            Text(L10n.string("settings.navigation.reorder_hint"))
        }
        .listSectionSeparator(.hidden)
    }
}

private struct NavigationAvailableSection: View {
    let tabs: [AppTab]
    let add: (AppTab) -> Void
    private let optionalTabs: [AppTab] = [.bookshelf, .messages, .history, .likes]

    var body: some View {
        Section {
            ForEach(optionalTabs.filter { !tabs.contains($0) }) { tab in
                Button { add(tab) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill").frame(width: 32, height: 44)
                        Label(tab.title, systemImage: tab.systemImage)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 44)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(tab == optionalTabs.last(where: { !tabs.contains($0) }) ? .hidden : .visible, edges: .bottom)
                .disabled(tabs.count == 5)
                .accessibilityLabel(L10n.string("settings.navigation.add_format", tab.title))
            }
        } header: {
            Text(L10n.string("settings.navigation.available"))
        } footer: {
            Text(L10n.string(tabs.count == 5 ? "settings.navigation.limit_hint" : "settings.navigation.available_hint"))
        }
        .listSectionSeparator(.hidden)
    }
}

private struct NavigationResetSection: View {
    let reset: () -> Void

    var body: some View {
        Section {
            Button(L10n.string("settings.navigation.reset"), action: reset)
        }
    }
}
