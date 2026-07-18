import PhotosUI
import SwiftUI
import YamiboXCore

struct SettingsFavoritesView: View {
    let viewModel: SettingsFavoritesViewModel

    @StateObject private var favoriteRemoteSync: FavoriteRemoteSyncSession
    @StateObject private var updateMonitor: FavoriteUpdateMonitor

    @State private var showingFavoriteRemoteSyncProgress = false
    @State private var showingFavoriteBackgroundPicker = false
    @State private var favoriteBackgroundPickerItem: PhotosPickerItem?
    @State private var favoriteBackgroundPickerPurpose = FavoriteBackgroundPickerPurpose.initial
    @State private var favoriteBackgroundEditorDraft: FavoriteBackgroundEditorDraft?

    init(dependencies: SettingsDependencies, viewModel: SettingsFavoritesViewModel) {
        self.viewModel = viewModel
        _favoriteRemoteSync = StateObject(wrappedValue: FavoriteRemoteSyncSession(
            libraryStore: dependencies.library.localFavoriteLibraryStore,
            runStore: dependencies.library.favoriteSyncRunStore,
            contentCoverStore: dependencies.library.contentCoverStore,
            mangaDirectoryStore: dependencies.library.mangaDirectoryStore,
            settingsStore: dependencies.library.settingsStore,
            makeFavoriteRepository: dependencies.library.makeFavoriteRepository,
            makeForumThreadReaderRepository: dependencies.library.makeForumThreadReaderRepository,
            makeThreadRouteResolver: dependencies.library.makeThreadRouteResolver
        ))
        _updateMonitor = StateObject(wrappedValue: FavoriteUpdateMonitor(
            updateStore: dependencies.library.favoriteUpdateStore,
            libraryStore: dependencies.library.localFavoriteLibraryStore,
            makeForumThreadReaderRepository: dependencies.library.makeForumThreadReaderRepository,
            settingsStore: dependencies.library.settingsStore,
            notifier: UserNotificationFavoriteUpdateNotifier()
        ))
    }

    var body: some View {
        Form {
            Section(L10n.string("settings.section.favorites_browsing")) {
                Picker(
                    L10n.string("favorites.layout"),
                    selection: favoriteLayoutModeBinding
                ) {
                    ForEach(FavoriteLibraryLayoutMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImageName)
                            .tag(mode)
                    }
                }
                .disabled(viewModel.isBusy)

                Picker(
                    L10n.string("favorites.sort"),
                    selection: favoriteSortOrderBinding
                ) {
                    ForEach(LocalFavoriteLibrarySortOrder.allCases) { sortOrder in
                        Text(sortOrder.title)
                            .tag(sortOrder)
                    }
                }
                .disabled(viewModel.isBusy)

                Toggle(
                    L10n.string("favorites.sort.descending"),
                    isOn: favoriteSortDescendingBinding
                )
                .disabled(viewModel.isBusy)

                Toggle(
                    L10n.string("favorites.category.show_counts"),
                    isOn: favoriteShowsCategoryCountsBinding
                )
                .disabled(viewModel.isBusy)
            }

            Section(L10n.string("settings.section.appearance")) {
                Button {
                    openFavoriteBackgroundEditorOrPicker()
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.favorite_background"),
                        value: favoriteBackgroundStatusLabel,
                        showsChevronAfterValue: true
                    )
                }
                .disabled(viewModel.isBusy)
            }

            Section {
                if favoriteRemoteSync.snapshot != nil {
                    Button {
                        showingFavoriteRemoteSyncProgress = true
                    } label: {
                        SystemSettingsRow(
                            title: L10n.string("settings.favorite_sync"),
                            value: favoriteRemoteSyncStatusLabel,
                            showsChevronAfterValue: true,
                            titleColor: .accentColor
                        )
                    }
                    .disabled(viewModel.isBusy)
                }

                Toggle(
                    L10n.string("settings.favorite_add_sync_prompt"),
                    isOn: favoriteAddSyncPromptBinding
                )
                .disabled(viewModel.isBusy)

                if !viewModel.favoriteAddSyncPromptEnabled {
                    Picker(
                        L10n.string("settings.favorite_add_sync_default"),
                        selection: favoriteAddSyncDefaultBinding
                    ) {
                        Text(L10n.string("favorites.quick.add_prompt.sync")).tag(true)
                        Text(L10n.string("favorites.quick.add_prompt.local_only")).tag(false)
                    }
                    .disabled(viewModel.isBusy)
                }

                Toggle(
                    L10n.string("settings.favorite_remove_sync_prompt"),
                    isOn: favoriteRemoveRemotePromptBinding
                )
                .disabled(viewModel.isBusy)

                if !viewModel.favoriteRemoveRemotePromptEnabled {
                    Picker(
                        L10n.string("settings.favorite_remove_sync_default"),
                        selection: favoriteRemoveRemoteDefaultBinding
                    ) {
                        Text(L10n.string("favorites.quick.remove_prompt.both")).tag(true)
                        Text(L10n.string("favorites.quick.remove_prompt.local_only")).tag(false)
                    }
                    .disabled(viewModel.isBusy)
                }
            } header: {
                Text(L10n.string("settings.section.favorite_sync_behavior"))
            } footer: {
                Text(L10n.string("settings.favorite_sync_behavior.footer"))
            }

            Section {
                Toggle(
                    L10n.string("settings.favorite_smart_manga_bulk_delete"),
                    isOn: favoriteSmartMangaBulkDeleteBinding
                )
                .disabled(viewModel.isBusy)
            } header: {
                Text(L10n.string("settings.section.favorite_smart_manga_management"))
            } footer: {
                Text(L10n.string("settings.favorite_smart_manga_bulk_delete.footer"))
            }

            FavoriteUpdateSettingsSection(updateMonitor: updateMonitor)
        }
        .navigationTitle(L10n.string("settings.section.favorites"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isBusy {
                ProgressView()
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            await favoriteRemoteSync.load()
        }
        .sheet(isPresented: $showingFavoriteRemoteSyncProgress) {
            NavigationStack {
                FavoriteRemoteSyncProgressSheet(
                    snapshot: favoriteRemoteSync.snapshot,
                    onResume: {
                        await favoriteRemoteSync.resume()
                    },
                    onInterrupt: {
                        await favoriteRemoteSync.interrupt()
                    },
                    onHide: {
                        await favoriteRemoteSync.hideCard()
                    }
                )
            }
        }
        .photosPicker(
            isPresented: $showingFavoriteBackgroundPicker,
            selection: $favoriteBackgroundPickerItem,
            matching: .images
        )
        .onChange(of: favoriteBackgroundPickerItem) { _, item in
            guard let item else { return }
            Task {
                await handleFavoriteBackgroundPickerItem(item)
                favoriteBackgroundPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: favoriteBackgroundEditorIsPresented) {
            if favoriteBackgroundEditorDraft != nil {
                FavoriteBackgroundEditorView(
                    draft: favoriteBackgroundEditorDraftBinding,
                    onCancel: {
                        favoriteBackgroundEditorDraft = nil
                    },
                    onChangeImage: {
                        favoriteBackgroundPickerPurpose = .replacement
                        showingFavoriteBackgroundPicker = true
                    },
                    onApply: { draft in
                        await applyFavoriteBackgroundDraft(draft)
                    }
                )
            }
        }
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

    private var favoriteBackgroundStatusLabel: String {
        viewModel.favoriteBackground.isEnabled
            ? L10n.string("settings.favorite_background.custom")
            : L10n.string("settings.favorite_background.default")
    }

    private var favoriteRemoteSyncStatusLabel: String {
        guard let snapshot = favoriteRemoteSync.snapshot else {
            return L10n.string("favorites.sync.status.none")
        }
        switch snapshot.status {
        case .running:
            return L10n.string("favorites.sync.status.running")
        case .completed:
            return L10n.string("favorites.sync.status.completed")
        case .failed:
            return L10n.string("favorites.sync.status.failed")
        case .interrupted:
            return L10n.string("favorites.sync.status.interrupted")
        }
    }

    private var favoriteLayoutModeBinding: Binding<FavoriteLibraryLayoutMode> {
        Binding(
            get: { viewModel.favoriteLayoutMode },
            set: { viewModel.updateFavoriteLayoutMode($0) }
        )
    }

    private var favoriteSortOrderBinding: Binding<LocalFavoriteLibrarySortOrder> {
        Binding(
            get: { viewModel.favoriteSortOrder },
            set: { viewModel.updateFavoriteSortOrder($0) }
        )
    }

    private var favoriteSortDescendingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteSortDescending },
            set: { viewModel.updateFavoriteSortDescending($0) }
        )
    }

    private var favoriteShowsCategoryCountsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteShowsCategoryCounts },
            set: { viewModel.updateFavoriteShowsCategoryCounts($0) }
        )
    }

    private var favoriteAddSyncPromptBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteAddSyncPromptEnabled },
            set: { viewModel.updateFavoriteAddSyncPromptEnabled($0) }
        )
    }

    private var favoriteAddSyncDefaultBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteAddSyncDefault },
            set: { viewModel.updateFavoriteAddSyncDefault($0) }
        )
    }

    private var favoriteRemoveRemotePromptBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteRemoveRemotePromptEnabled },
            set: { viewModel.updateFavoriteRemoveRemotePromptEnabled($0) }
        )
    }

    private var favoriteRemoveRemoteDefaultBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteRemoveRemoteDefault },
            set: { viewModel.updateFavoriteRemoveRemoteDefault($0) }
        )
    }

    private var favoriteSmartMangaBulkDeleteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteSmartMangaBulkDeleteEnabled },
            set: { viewModel.updateFavoriteSmartMangaBulkDeleteEnabled($0) }
        )
    }

    private var favoriteBackgroundEditorIsPresented: Binding<Bool> {
        Binding(
            get: { favoriteBackgroundEditorDraft != nil },
            set: { isPresented in
                if !isPresented {
                    favoriteBackgroundEditorDraft = nil
                }
            }
        )
    }

    private var favoriteBackgroundEditorDraftBinding: Binding<FavoriteBackgroundEditorDraft> {
        Binding(
            get: {
                favoriteBackgroundEditorDraft ?? FavoriteBackgroundEditorDraft(
                    imageData: nil,
                    imageSize: .zero,
                    settings: FavoriteBackgroundSettings()
                )
            },
            set: { favoriteBackgroundEditorDraft = $0 }
        )
    }

    private func openFavoriteBackgroundEditorOrPicker() {
        Task { @MainActor in
            if viewModel.favoriteBackground.isEnabled,
               let imageData = await viewModel.loadFavoriteBackgroundImageData(),
               let draft = FavoriteBackgroundEditorDraft.custom(
                   imageData: imageData,
                   settings: viewModel.favoriteBackground
               ) {
                favoriteBackgroundEditorDraft = draft
                return
            }

            favoriteBackgroundPickerPurpose = .initial
            showingFavoriteBackgroundPicker = true
        }
    }

    private func handleFavoriteBackgroundPickerItem(_ item: PhotosPickerItem) async {
        do {
            guard let sourceData = try await item.loadTransferable(type: Data.self) else {
                viewModel.errorMessage = L10n.string("favorite_background.load_failed")
                return
            }
            let imageData = try viewModel.normalizedFavoriteBackgroundImageData(from: sourceData)

            switch favoriteBackgroundPickerPurpose {
            case .initial:
                guard let draft = FavoriteBackgroundEditorDraft.custom(imageData: imageData) else {
                    viewModel.errorMessage = L10n.string("favorite_background.load_failed")
                    return
                }
                favoriteBackgroundEditorDraft = draft
            case .replacement:
                guard var draft = favoriteBackgroundEditorDraft, draft.replaceImage(with: imageData) else {
                    viewModel.errorMessage = L10n.string("favorite_background.load_failed")
                    return
                }
                favoriteBackgroundEditorDraft = draft
            }
        } catch {
            viewModel.errorMessage = L10n.string("favorite_background.load_failed")
        }
    }

    private func applyFavoriteBackgroundDraft(_ draft: FavoriteBackgroundEditorDraft) async -> Bool {
        let didApply: Bool
        if let imageData = draft.imageData {
            didApply = await viewModel.applyFavoriteBackground(
                imageData: imageData,
                draftSettings: draft.settings
            )
        } else {
            didApply = await viewModel.restoreDefaultFavoriteBackground()
        }

        if didApply {
            favoriteBackgroundEditorDraft = nil
        }
        return didApply
    }
}

private enum FavoriteBackgroundPickerPurpose {
    case initial
    case replacement
}
