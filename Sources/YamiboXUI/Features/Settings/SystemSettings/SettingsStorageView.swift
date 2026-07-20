import SwiftUI
import YamiboXCore

struct SettingsStorageView: View {
    let dependencies: SettingsDependencies
    let viewModel: SettingsStorageViewModel
    /// This page owns the navigation into the two management sub-pages, so it
    /// carries their view models purely to hand them on.
    let offlineCacheManagement: OfflineCacheManagementViewModel
    let mangaDirectoryManagement: MangaDirectoryManagementViewModel
    /// Called after a successful reset, before `viewModel.resetApplication()`'s
    /// caller-provided completion runs — lets the owning navigation stack pop
    /// back out of Settings first, since the app state it just wiped includes
    /// whatever this stack is showing.
    let onReset: () async -> Void

    @State private var showingWebDAVSettings = false
    @State private var showingOfflineCacheManagement = false
    @State private var showingMangaDirectoryManagement = false
    @State private var pendingConfirmation: SystemSettingsConfirmation?

    var body: some View {
        Form {
            Section(L10n.string("settings.section.backup_sync")) {
                Button {
                    openWebDAVSettings()
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.webdav_sync"),
                        titleColor: .accentColor
                    )
                }
                .disabled(viewModel.isBusy)
            }

            Section(L10n.string("settings.section.storage")) {
                Button {
                    pendingConfirmation = .clearWebReaderCache
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.clear_web_reader_cache"),
                        value: viewModel.webReaderCacheLabel
                    )
                }
                .disabled(viewModel.isBusy)

                Button {
                    pendingConfirmation = .clearImageCache
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.clear_image_cache"),
                        showsChevron: false
                    )
                }
                .disabled(viewModel.isBusy)

                Button {
                    pendingConfirmation = .clearOtherCaches
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.clear_other_caches"),
                        showsChevron: false
                    )
                }
                .disabled(viewModel.isBusy)

                Button {
                    pendingConfirmation = .clearContentCoverCache
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.clear_content_cover_cache"),
                        value: viewModel.contentCoverCacheLabel
                    )
                }
                .disabled(viewModel.isBusy)

                Button {
                    showingMangaDirectoryManagement = true
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.manga_directory.cleanup"),
                        value: viewModel.mangaDirectoryCacheLabel,
                        showsChevronAfterValue: true
                    )
                }
                .disabled(viewModel.isBusy)

                Button {
                    showingOfflineCacheManagement = true
                } label: {
                    SystemSettingsRow(
                        title: L10n.string("settings.offline_cache.cleanup"),
                        value: viewModel.offlineCacheLabel,
                        showsChevronAfterValue: true
                    )
                }
                .disabled(viewModel.isBusy)
            }

            Section(L10n.string("settings.section.reset")) {
                Button(role: .destructive) {
                    pendingConfirmation = .resetApplication
                } label: {
                    Text(L10n.string("settings.reset_application"))
                }
                .disabled(viewModel.isBusy)
            }
        }
        .navigationTitle(L10n.string("settings.section.data_storage"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(content: loadingOverlay)
        .navigationDestination(isPresented: $showingWebDAVSettings) {
            WebDAVSyncSettingsView(dependencies: dependencies.webDAVSync)
        }
        .navigationDestination(isPresented: $showingOfflineCacheManagement) {
            OfflineCacheManagementView(viewModel: offlineCacheManagement)
        }
        .navigationDestination(isPresented: $showingMangaDirectoryManagement) {
            MangaDirectoryManagementView(viewModel: mangaDirectoryManagement)
        }
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
        .destructiveConfirmationAlert(
            item: $pendingConfirmation,
            title: \.title,
            actionTitle: \.buttonTitle,
            message: \.message
        ) { confirmation in
            Task {
                await handleConfirmation(confirmation)
            }
        }
    }

    @ViewBuilder
    private func loadingOverlay() -> some View {
        if viewModel.isBusy {
            let title = viewModel.activeAction == .resettingApplication
                ? L10n.string("settings.resetting_application")
                : L10n.string("common.loading")
            ProgressView(title)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }


    private func openWebDAVSettings() {
        Task { @MainActor in
            let session = await dependencies.sessionStore.load()
            if session.isLoggedIn, !session.cookie.isEmpty {
                showingWebDAVSettings = true
            } else {
                viewModel.errorMessage = L10n.string("webdav.error.login_required")
            }
        }
    }

    private func handleConfirmation(_ confirmation: SystemSettingsConfirmation) async {
        switch confirmation {
        case .clearWebReaderCache:
            _ = await viewModel.clearWebReaderCache()
        case .clearContentCoverCache:
            _ = await viewModel.clearContentCoverCache()
        case .clearOtherCaches:
            _ = await viewModel.clearOtherCaches()
        case .clearImageCache:
            _ = await viewModel.clearImageCache()
        case .resetApplication:
            let didReset = await viewModel.resetApplication()
            guard didReset else { return }
            await onReset()
        case .restoreBoardReaderDefaults, .signOut:
            break
        }
    }
}
