import SwiftUI
import UIKit
import YamiboXCore

public struct MineHomeView: View {
    @State private var viewModel: MineHomeViewModel
    @State private var navigator: ForumDestinationNavigator
    @State private var showingLoginSheet = false
    @State private var isSettingsPushed = false
    @State private var isOfflineCacheQueuePushed = false
    @State private var isMyLikesPushed = false

    private let settingsDependencies: SettingsDependencies
    private let sessionStore: SessionStore
    private let appModel: YamiboAppModel
    private let likeDependencies: LikeDependencies
    private let messageUnreadWorkflow: MessageUnreadWorkflow

    public init(
        dependencies: AccountDependencies,
        settingsDependencies: SettingsDependencies,
        appModel: YamiboAppModel,
        likeDependencies: LikeDependencies
    ) {
        _viewModel = State(initialValue: MineHomeViewModel(dependencies: dependencies))
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumDependencies,
            appModel: appModel,
            mode: .forumTab
        ))
        self.settingsDependencies = settingsDependencies
        self.sessionStore = dependencies.sessionStore
        self.appModel = appModel
        self.likeDependencies = likeDependencies
        self.messageUnreadWorkflow = dependencies.messageUnreadWorkflow
    }

    public var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                MineSidebarView(
                    viewModel: viewModel, navigator: navigator, appModel: appModel,
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
            MineLoginSheet(viewModel: viewModel, sessionStore: sessionStore, appModel: appModel) {
                showingLoginSheet = false
            }
        }
    }

    private var mineNavigation: some View {
        ForumDestinationStackView(navigator: navigator) {
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
                    offlineCacheQueueCount: viewModel.offlineQueue.entryCount,
                    unreadMessageCount: messageUnreadWorkflow.totalCount,
                    showMessages: {
                        if viewModel.isLoggedIn {
                            navigator.openMessageCenter(tab: .privateMessages)
                        } else {
                            showingLoginSheet = true
                        }
                    },
                    showOfflineCacheQueue: {
                        isOfflineCacheQueuePushed = true
                    },
                    showMyLikes: {
                        isMyLikesPushed = true
                    },
                    showHistory: {
                        // Keep history and its thread pages in the same path
                        // so a thread push preserves the history page below it.
                        navigator.push(.browsingHistory)
                    }
                )
                MineSettingsSection(
                    showSettings: {
                        isSettingsPushed = true
                    }
                )
            }
            .listStyle(.insetGrouped)
            .messageUnreadTabAccessibility(count: messageUnreadWorkflow.totalCount)
            .navigationTitle(L10n.string("tab.mine"))
            .yamiboInlineNavigationTitleDisplayMode()
            .refreshable {
                await viewModel.refreshProfile()
                await messageUnreadWorkflow.refresh(force: true)
            }
            .navigationDestination(isPresented: $isSettingsPushed) {
                settingsScreen
            }
            .navigationDestination(isPresented: $isOfflineCacheQueuePushed) {
                OfflineCacheQueueScreen(viewModel: viewModel.offlineQueue)
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
        }
    }

    private var settingsScreen: some View {
        SettingsHomeView(
            dependencies: settingsDependencies,
            peripheralInput: appModel.peripheralInput,
            onSignOut: signOut,
            onApplicationReset: {
                await appModel.bootstrap()
            },
            onClose: {
                isSettingsPushed = false
            },
            accountSwitcher: appModel.appContext.accountSwitcher
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
