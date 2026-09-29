import SwiftUI
import UIKit
import YamiboXCore

public struct MineHomeView: View {
    @State private var viewModel: MineHomeViewModel
    @State private var navigator: ForumDestinationNavigator
    @State private var showingLoginSheet = false
    @State private var isSettingsPushed = false
    @State private var isDownloadManagementPushed = false
    @State private var isMyLikesPushed = false
    @State private var showsBookshelf = false
    @State private var initialSettingsDestination: SettingsSidebarDestination?

    private let settingsDependencies: SettingsDependencies
    private let sessionStore: SessionStore
    private let accountSwitcher: AccountSwitchCoordinator
    private let appModel: YamiboAppModel
    private let likeDependencies: LikeDependencies
    private let messageUnreadWorkflow: MessageUnreadWorkflow

    public init(
        dependencies: AccountDependencies,
        forumDependencies: ForumNavigationDependencies,
        accountSwitcher: AccountSwitchCoordinator,
        settingsDependencies: SettingsDependencies,
        appModel: YamiboAppModel,
        likeDependencies: LikeDependencies
    ) {
        _viewModel = State(initialValue: MineHomeViewModel(dependencies: dependencies))
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: forumDependencies,
            actions: appModel.forumNavigationActions,
            mode: .forumTab
        ))
        self.settingsDependencies = settingsDependencies
        self.sessionStore = dependencies.sessionStore
        self.accountSwitcher = accountSwitcher
        self.appModel = appModel
        self.likeDependencies = likeDependencies
        self.messageUnreadWorkflow = dependencies.messageUnreadWorkflow
    }

    public var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                MineSidebarView(
                    viewModel: viewModel, navigator: navigator, appModel: appModel,
                    accountSwitcher: accountSwitcher,
                    settingsDependencies: settingsDependencies, likeDependencies: likeDependencies,
                    messageUnreadWorkflow: messageUnreadWorkflow,
                    showLogin: { showingLoginSheet = true }, checkIn: checkIn,
                    onSignOut: signOut
                )
            } else {
                mineNavigation
            }
        }
        .task { await viewModel.load() }
        .task(id: appModel.mineNavigationRequest?.id) {
            guard let request = appModel.mineNavigationRequest else { return }
            switch request.target {
            case .login:
                _ = appModel.claimMineNavigationRequest()
                showingLoginSheet = true
            case let .settings(destination):
                guard UIDevice.current.userInterfaceIdiom != .pad else { return }
                _ = appModel.claimMineNavigationRequest()
                initialSettingsDestination = destination
                isSettingsPushed = true
            case let .page(destination):
                guard UIDevice.current.userInterfaceIdiom != .pad else { return }
                if let tab = destination.tab, appModel.selectConfiguredTab(tab) {
                    _ = appModel.claimMineNavigationRequest()
                    return
                }
                if destination.requiresLogin { await viewModel.reloadAccountSnapshot() }
                guard !Task.isCancelled, appModel.mineNavigationRequest?.id == request.id else { return }
                _ = appModel.claimMineNavigationRequest()
                guard !destination.requiresLogin || viewModel.isLoggedIn else {
                    showingLoginSheet = true
                    return
                }
                switch destination {
                case .profile: navigator.push(.userSpace(uid: nil, name: nil, section: .space, subPage: .profile))
                case .messages: navigator.openMessageCenter(tab: .privateMessages)
                case .history: navigator.push(.browsingHistory)
                case .likes: isMyLikesPushed = true
                case .downloads: isDownloadManagementPushed = true
                case .bookshelf: showsBookshelf = true
                }
            }
        }
        .task {
            for await _ in sessionStore.changes() {
                guard !Task.isCancelled else { return }
                await viewModel.reloadAccountSnapshot()
            }
        }
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: errorIsPresented
        ) {
            Button(L10n.string("common.ok")) { clearErrorMessages() }
        }
        .transientMessage(viewModel.checkInResultMessage) {
            viewModel.checkInResultMessage = nil
        }
        .sheet(isPresented: $showingLoginSheet) {
            MineLoginSheet(viewModel: viewModel, accountSwitcher: accountSwitcher) {
                showingLoginSheet = false
            }
        }
    }

    private var mineNavigation: some View {
        ForumDestinationStackView(navigator: navigator, appModel: appModel) {
            List {
                if viewModel.isLoggedIn {
                    MineProfileSection(
                        profile: viewModel.profile,
                        avatarLoader: viewModel.profileAvatarLoader,
                        avatarReloadDate: viewModel.session.lastUpdatedAt,
                        isRefreshing: viewModel.isRefreshingProfile,
                        isInteractionDisabled: viewModel.isBusy,
                        showProfile: {
                            navigator.push(.userSpace(uid: nil, name: nil, section: .space, subPage: .profile))
                        }
                    )
                } else {
                    MineLoggedOutProfileSection(isInteractionDisabled: viewModel.isBusy) {
                        showingLoginSheet = true
                    }
                }

                MineCheckInSection(
                    isLoggedIn: viewModel.isLoggedIn,
                    isCheckingIn: viewModel.isCheckingIn,
                    hasCheckedInToday: viewModel.hasCheckedInToday,
                    isInteractionDisabled: viewModel.isBusy,
                    checkIn: checkIn
                )
                MineLibraryEntriesSection(
                    downloadQueueCount: viewModel.offlineQueue.entryCount,
                    unreadMessageCount: messageUnreadWorkflow.totalCount,
                    showMessages: {
                        if appModel.selectConfiguredTab(.messages) { return }
                        if viewModel.isLoggedIn {
                            navigator.openMessageCenter(tab: .privateMessages)
                        } else {
                            showingLoginSheet = true
                        }
                    },
                    showDownloadManagement: {
                        isDownloadManagementPushed = true
                    },
                    showMyLikes: {
                        if appModel.selectConfiguredTab(.likes) { return }
                        isMyLikesPushed = true
                    },
                    showHistory: {
                        if appModel.selectConfiguredTab(.history) { return }
                        // Keep history and its thread pages in the same path
                        // so a thread push preserves the history page below it.
                        navigator.push(.browsingHistory)
                    }
                )
                MineSettingsSection(
                    showSettings: {
                        initialSettingsDestination = nil
                        isSettingsPushed = true
                    }
                )
            }
            .listStyle(.insetGrouped)
            .messageUnreadTabAccessibility(count: appModel.unreadCount(for: .mine))
            .navigationTitle(L10n.string("tab.mine"))
            .yamiboInlineNavigationTitleDisplayMode()
            .refreshable {
                await viewModel.refreshProfile()
                await messageUnreadWorkflow.refresh(force: true)
            }
            .navigationDestination(isPresented: $isSettingsPushed) {
                settingsScreen
            }
            .navigationDestination(isPresented: $isDownloadManagementPushed) {
                DownloadsScreen(initialPage: .management, management: viewModel.downloadManagement, queue: viewModel.offlineQueue)
            }
            .navigationDestination(isPresented: $isMyLikesPushed) {
                LikeWorkListView(
                    likeDependencies: likeDependencies,
                    contentCoverStore: settingsDependencies.library.contentCoverStore,
                    favoriteLibraryStore: settingsDependencies.library.localFavoriteLibraryStore,
                    settingsStore: settingsDependencies.settingsStore,
                    appModel: appModel
                )
            }
            .navigationDestination(isPresented: $showsBookshelf) {
                MineBookshelfView(appModel: appModel, navigator: navigator)
            }
        }
    }

    private var settingsScreen: some View {
        SettingsHomeView(
            dependencies: settingsDependencies,
            initialDestination: initialSettingsDestination,
            peripheralInput: appModel.peripheralInput,
            onSignOut: signOut,
            onApplicationReset: {
                await appModel.bootstrap()
            },
            onClose: {
                isSettingsPushed = false
            },
            accountSwitcher: accountSwitcher
        )
    }

    private func checkIn() {
        if viewModel.isLoggedIn {
            Task { await viewModel.checkIn() }
        } else {
            showingLoginSheet = true
        }
    }

    private func signOut() async -> LoadFailureDetails? {
        await viewModel.signOut()
        let details = viewModel.errorMessage.map {
            viewModel.errorDetails ?? LoadFailureDetails(message: $0)
        }
        viewModel.errorMessage = nil
        return details
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: {
                viewModel.errorMessage != nil
                    && !showingLoginSheet
            },
            set: { isPresented in
                if !isPresented {
                    clearErrorMessages()
                }
            }
        )
    }

    private func clearErrorMessages() {
        viewModel.errorMessage = nil
    }

}
