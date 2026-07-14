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
    private let appModel: YamiboAppModel
    private let likeDependencies: LikeDependencies

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
        self.appModel = appModel
        self.likeDependencies = likeDependencies
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
            }
            .task {
                await viewModel.load()
            }
            .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
                Button(L10n.string("common.ok")) {
                    clearErrorMessages()
                }
            }, message: {
                Text(viewModel.errorMessage ?? viewModel.offlineQueue.errorMessage ?? "")
            })
            .transientMessage(viewModel.checkInResultMessage) {
                viewModel.checkInResultMessage = nil
            }
            .sheet(isPresented: $showingLoginSheet) {
                MineLoginSheet(viewModel: viewModel) {
                    showingLoginSheet = false
                }
            }
            .navigationDestination(isPresented: $isSettingsPushed) {
                SettingsHomeView(
                    dependencies: settingsDependencies,
                    peripheralInput: appModel.peripheralInput,
                    onSignOut: {
                        await viewModel.signOut()
                        let message = viewModel.errorMessage
                        viewModel.errorMessage = nil
                        return message
                    },
                    onApplicationReset: {
                        await appModel.bootstrap()
                    },
                    onClose: {
                        isSettingsPushed = false
                    }
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
                (viewModel.errorMessage != nil || viewModel.offlineQueue.errorMessage != nil)
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
        viewModel.offlineQueue.errorMessage = nil
    }

}
