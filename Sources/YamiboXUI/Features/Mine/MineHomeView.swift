import SwiftUI
import YamiboXCore

public struct MineHomeView: View {
    @State private var viewModel: MineHomeViewModel
    @State private var navigator: ForumDestinationNavigator
    @State private var showingLoginSheet = false
    @State private var isSettingsPushed = false
    @State private var isOfflineCacheQueuePushed = false
    @State private var isMyLikesPushed = false
    @State private var isHistoryPushed = false

    private let settingsDependencies: SettingsDependencies
    private let sessionStore: SessionStore
    private let appModel: YamiboAppModel
    private let likeDependencies: LikeDependencies
    private let messageUnreadWorkflow: MessageUnreadWorkflow?

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
                    checkIn: {
                        if viewModel.isLoggedIn {
                            Task {
                                await viewModel.checkIn()
                            }
                        } else {
                            showingLoginSheet = true
                        }
                    }
                )
                MineLibraryEntriesSection(
                    offlineCacheQueueCount: viewModel.offlineQueue.entryCount,
                    unreadMessageCount: messageUnreadWorkflow?.totalCount ?? 0,
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
                        isHistoryPushed = true
                    }
                )
                MineSettingsSection(
                    showSettings: {
                        isSettingsPushed = true
                    }
                )
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.string("tab.mine"))
            .yamiboInlineNavigationTitleDisplayMode()
            .refreshable {
                await viewModel.refreshProfile()
                await messageUnreadWorkflow?.refresh(force: true)
            }
            .task {
                await viewModel.load()
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
                Button(L10n.string("common.ok")) {
                    clearErrorMessages()
                }
            }
            .transientMessage(viewModel.checkInResultMessage) {
                viewModel.checkInResultMessage = nil
            }
            .sheet(isPresented: $showingLoginSheet) {
                MineLoginSheet(
                    viewModel: viewModel,
                    sessionStore: sessionStore,
                    appModel: appModel
                ) {
                    showingLoginSheet = false
                }
            }
            .navigationDestination(isPresented: $isSettingsPushed) {
                SettingsHomeView(
                    dependencies: settingsDependencies,
                    peripheralInput: appModel.peripheralInput,
                    onSignOut: {
                        await viewModel.signOut()
                        let details = viewModel.errorMessage.map {
                            viewModel.errorDetails ?? LoadFailureDetails(message: $0)
                        }
                        viewModel.errorMessage = nil
                        return details
                    },
                    onApplicationReset: {
                        await appModel.bootstrap()
                    },
                    onClose: {
                        isSettingsPushed = false
                    },
                    accountSwitcher: appModel.appContext.accountSwitcher
                )
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
            .navigationDestination(isPresented: $isHistoryPushed) {
                BrowsingHistoryView(
                    dependencies: settingsDependencies.library,
                    appModel: appModel
                )
            }
        }
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
