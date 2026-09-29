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
    @State private var showsStartupPicker = false

    init(initial: AppNavigationSettings, save: @escaping (AppNavigationSettings) async throws -> Void) {
        self.initial = initial
        self.save = save
        _draft = State(initialValue: initial)
    }

    private var hasChanges: Bool { draft != initial }

    var body: some View {
        NavigationStack {
            List {
                NavigationPreviewSection(configuration: draft)
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
                NavigationAvailableSection(tabs: draft.tabs) { tab in
                    guard draft.tabs.count < 5 else { return }
                    update(tabs: draft.tabs + [tab])
                }
                NavigationStartupSection(startup: draft.startupTab, showsFallbackNotice: startupChanged) {
                    showsStartupPicker = true
                }
                NavigationResetSection {
                    confirmsReset = true
                }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(isSaving)
            .navigationTitle(L10n.string("settings.navigation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsStartupPicker) {
                NavigationStartupPicker(tabs: draft.tabs, selection: draft.startupTab) { tab in
                    draft = AppNavigationSettings(tabs: draft.tabs, startupTab: tab)
                    startupChanged = false
                    showsStartupPicker = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
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
                        if isSaving { ProgressView() } else { Text("保存").fontWeight(.semibold) }
                    }
                    .disabled(!hasChanges || isSaving)
                }
            }
        }
        .tint(theme.controlAccent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasChanges || isSaving)
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("恢复默认导航栏和启动页？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复默认配置") { draft = AppNavigationSettings(); startupChanged = false }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复为书架、论坛、收藏、我的，启动时进入书架。保存后生效。")
        }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
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

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("预览 · 启动时进入\(configuration.startupTab.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    NavigationBarPreview(configuration: configuration)
                    ScrollView(.horizontal) {
                        NavigationBarPreview(configuration: configuration)
                    }.scrollIndicators(.hidden)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct NavigationBarPreview: View {
    let configuration: AppNavigationSettings
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(configuration.tabs) { tab in
                VStack(spacing: 8) {
                    Image(systemName: tab.systemImage).font(.title3)
                    Text(tab.title).font(.caption).fixedSize()
                }
                .foregroundStyle(tab == configuration.startupTab ? theme.controlAccent : .secondary)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            ForEach(tabs) { tab in
                HStack(spacing: 12) {
                    if !tab.isRequired {
                        Button { remove(tab) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除\(tab.title)")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(tab.title, systemImage: tab.systemImage)
                        if tab.isRequired, dynamicTypeSize.isAccessibilitySize {
                            Text("必选").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if tab.isRequired, !dynamicTypeSize.isAccessibilitySize {
                        Text("必选").font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                }
                .accessibilityAction(named: Text("上移")) { move(tab, -1) }
                .accessibilityAction(named: Text("下移")) { move(tab, 1) }
            }
            .onMove(perform: reorder)
        } header: {
            Text("已添加 · \(tabs.count)/5")
        } footer: {
            Text("拖动右侧手柄调整顺序。论坛、收藏和我的为必选项目。")
        }
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
                        Image(systemName: "plus.circle.fill").frame(minWidth: 44, minHeight: 44)
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                }
                .disabled(tabs.count == 5)
                .accessibilityLabel("添加\(tab.title)")
            }
        } header: {
            Text("可添加")
        } footer: {
            Text(tabs.count == 5 ? "最多添加 5 项，请先移除一个可选项目。" : "未加入导航栏的页面仍可从「我的」进入。")
        }
    }
}

private struct NavigationStartupSection: View {
    let startup: AppTab
    let showsFallbackNotice: Bool
    let open: () -> Void

    var body: some View {
        Section {
            // Native navigation-link pickers are disabled while the list is editing.
            Button(action: open) {
                SystemSettingsRow(title: "启动时进入", value: startup.title, showsChevronAfterValue: true)
                    .foregroundStyle(.primary)
            }
        } footer: {
            if showsFallbackNotice {
                Text("原启动页已移除，启动页已改为\(startup.title)。")
            }
        }
    }
}

private struct NavigationStartupPicker: View {
    let tabs: [AppTab]
    let selection: AppTab
    let select: (AppTab) -> Void

    var body: some View {
        List(tabs) { tab in
            Button { select(tab) } label: {
                HStack {
                    Label(tab.title, systemImage: tab.systemImage).foregroundStyle(.primary)
                    Spacer()
                    if tab == selection { Image(systemName: "checkmark") }
                }
            }
            .accessibilityAddTraits(tab == selection ? .isSelected : [])
        }
        .environment(\.editMode, .constant(.inactive))
        .navigationTitle("启动时进入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NavigationResetSection: View {
    let reset: () -> Void

    var body: some View {
        Section {
            Button("恢复默认配置", action: reset)
        }
    }
}
