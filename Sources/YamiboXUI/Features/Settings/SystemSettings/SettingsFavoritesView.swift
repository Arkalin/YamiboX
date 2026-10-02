import SwiftUI
import UIKit
import YamiboXCore

struct SettingsFavoritesView: View {
    let viewModel: SettingsFavoritesViewModel
    @Environment(\.appTheme) private var appTheme

    @StateObject private var favoriteRemoteSync: FavoriteRemoteSyncSession
    @StateObject private var updateMonitor: FavoriteUpdateMonitor

    @State private var showingFavoriteRemoteSyncProgress = false

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

                AppThemeSwitch(
                    L10n.string("favorites.sort.descending"),
                    isOn: favoriteSortDescendingBinding
                )
                .disabled(viewModel.isBusy)

                AppThemeSwitch(
                    L10n.string("favorites.category.show_counts"),
                    isOn: favoriteShowsCategoryCountsBinding
                )
                .disabled(viewModel.isBusy)

                Picker(selection: favoriteItemTapActionBinding) {
                    ForEach(FavoriteItemTapAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                } label: {
                    Text(L10n.string("settings.favorite_item_tap_action"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .pickerStyle(.menu)
                .disabled(viewModel.isBusy)
            }

            Section {
                CustomBackgroundSettingsRow(
                    title: L10n.string("settings.favorite_background"),
                    settings: viewModel.favoriteBackground,
                    imageStore: viewModel.dependencies.favoriteBackgroundImageStore,
                    persistence: viewModel.dependencies.favoriteBackgroundPersistence,
                    isBusy: viewModel.isBusy,
                    onSaved: { viewModel.favoriteBackground = $0 }
                ) { _, _, _ in EmptyView() }

                if isPadDevice {
                    favoriteGridCardScaleRow
                }

                AppThemeSwitch(
                    L10n.string("settings.favorite_smart_manga_badge"),
                    isOn: favoriteSmartMangaBadgeBinding
                )
                .disabled(viewModel.isBusy)
            } header: {
                Text(L10n.string("settings.section.appearance"))
            } footer: {
                if isPadDevice {
                    Text(L10n.string("settings.favorite_grid_card_scale.footer"))
                }
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
                            titleColor: appTheme.controlAccent
                        )
                    }
                    .disabled(viewModel.isBusy)
                }

                AppThemeSwitch(
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

                AppThemeSwitch(
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
                AppThemeSwitch(
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
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: errorIsPresented
        ) {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
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

    /// The grid card size is an iPad-only concept (see
    /// `FavoriteLibrarySettings.gridCardScale`); iPhone hides the slider
    /// entirely rather than offering a control that does nothing.
    private var isPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var favoriteGridCardScaleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("settings.favorite_grid_card_scale"))
                Spacer()
                Text(favoriteGridCardScalePercentLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: favoriteGridCardScaleBinding,
                in: FavoriteLibrarySettings.minimumGridCardScale...FavoriteLibrarySettings.maximumGridCardScale,
                step: 0.05
            ) {
                Text(L10n.string("settings.favorite_grid_card_scale"))
            } minimumValueLabel: {
                // Denser grid of smaller cards at the low end…
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                // …fewer, larger cards at the high end.
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
            } onEditingChanged: { isEditing in
                if !isEditing {
                    viewModel.commitFavoriteGridCardScale()
                }
            }
        }
        .disabled(viewModel.isBusy)
    }

    private var favoriteGridCardScalePercentLabel: String {
        "\(Int((viewModel.favoriteGridCardScale * 100).rounded()))%"
    }

    /// Drag ticks only preview in memory; the commit happens once in
    /// `onEditingChanged(false)` — see `commitFavoriteGridCardScale()`.
    private var favoriteGridCardScaleBinding: Binding<Double> {
        Binding(
            get: { viewModel.favoriteGridCardScale },
            set: { viewModel.previewFavoriteGridCardScale($0) }
        )
    }

    private var favoriteLayoutModeBinding: Binding<FavoriteLibraryLayoutMode> {
        Binding(
            get: { viewModel.favoriteLayoutMode },
            set: { viewModel.updateFavoriteLayoutMode($0) }
        )
    }

    private var favoriteItemTapActionBinding: Binding<FavoriteItemTapAction> {
        Binding(
            get: { viewModel.favoriteItemTapAction },
            set: { viewModel.updateFavoriteItemTapAction($0) }
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

    private var favoriteSmartMangaBadgeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.favoriteSmartMangaBadgeEnabled },
            set: { viewModel.updateFavoriteSmartMangaBadgeEnabled($0) }
        )
    }

}
