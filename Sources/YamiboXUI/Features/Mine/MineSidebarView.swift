import SwiftUI
import UIKit
import YamiboXCore

struct MineSidebarView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let viewModel: MineHomeViewModel
    let navigator: ForumDestinationNavigator
    let appModel: YamiboAppModel
    let likeDependencies: LikeDependencies
    let messageUnreadWorkflow: MessageUnreadWorkflow?
    let showLogin: () -> Void
    let checkIn: () -> Void
    @State private var navigation: MineSidebarNavigationState
    @State private var settings: SettingsPresentationState

    init(
        viewModel: MineHomeViewModel,
        navigator: ForumDestinationNavigator,
        appModel: YamiboAppModel,
        settingsDependencies: SettingsDependencies,
        likeDependencies: LikeDependencies,
        messageUnreadWorkflow: MessageUnreadWorkflow?,
        showLogin: @escaping () -> Void,
        checkIn: @escaping () -> Void,
        onSignOut: @escaping @MainActor () async -> LoadFailureDetails?
    ) {
        self.viewModel = viewModel
        self.navigator = navigator
        self.appModel = appModel
        self.likeDependencies = likeDependencies
        self.messageUnreadWorkflow = messageUnreadWorkflow
        self.showLogin = showLogin
        self.checkIn = checkIn
        let navigation = MineSidebarNavigationState()
        _navigation = State(initialValue: navigation)
        _settings = State(initialValue: SettingsPresentationState(
            dependencies: settingsDependencies,
            peripheralInput: appModel.peripheralInput,
            onSignOut: onSignOut,
            onApplicationReset: { await appModel.bootstrap() },
            onClose: { navigation.returnToRoot() },
            accountSwitcher: appModel.appContext.accountSwitcher
        ))
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(preferredCompactColumn: $navigation.preferredCompactColumn) {
            NavigationStack(path: sidebarPath) {
                rootMenu
                    .navigationDestination(for: MineSidebarSection.self) { section in
                        categorySidebar(section)
                            .navigationBarBackButtonHidden(!canNavigate)
                    }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } detail: {
            ForumDestinationStackView(navigator: navigator) {
                detailContent
                    .id(navigation.detail?.identity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .top : [])
        .modifier(SettingsPresentationEffects(state: settings, isActive: navigation.section == .settings))
        .onChange(of: navigation.detail) { _, _ in
            navigator.path = []
        }
        .onChange(of: viewModel.isLoggedIn) { _, loggedIn in
            if !loggedIn { navigation.accountDidSignOut() }
        }
        .accessibilityIdentifier("mine.sidebar.workspace")
    }

    private var canNavigate: Bool {
        !navigation.isSelectingLikes && (navigation.section != .settings || settings.canNavigate)
    }

    private var sidebarPath: Binding<[MineSidebarSection]> {
        Binding { navigation.sidebarPath } set: { path in
            guard canNavigate else { return }
            navigation.setSidebarPath(path)
        }
    }

    private var rootMenu: some View {
        List(selection: rootSelection) {
            Section {
                Button {
                    if viewModel.isLoggedIn { navigation.show(.profile) } else { showLogin() }
                } label: {
                    profileLabel
                }
                .tag(MineSidebarDetail.profile)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("mine.sidebar.profile")
            }
            MineCheckInSection(
                isLoggedIn: viewModel.isLoggedIn,
                isCheckingIn: viewModel.isCheckingIn,
                hasCheckedInToday: viewModel.hasCheckedInToday,
                isInteractionDisabled: viewModel.isBusy,
                checkIn: checkIn
            )
            Section {
                Button {
                    if viewModel.isLoggedIn { navigation.show(.messages) } else { showLogin() }
                } label: {
                    Label(L10n.string("message_center.private_messages"), systemImage: "envelope.fill")
                        .badge(messageUnreadWorkflow?.totalCount ?? 0)
                }
                .tag(MineSidebarDetail.messages)
                .accessibilityIdentifier("mine.sidebar.messages")
                sectionLink(.history, icon: "clock.arrow.circlepath")
                sectionLink(.likes, icon: "heart.fill")
                Button { navigation.show(.downloads) } label: {
                    Label(L10n.string("mine.download_queue"), systemImage: "arrow.down.circle.fill")
                        .badge(viewModel.offlineQueue.entryCount)
                }
                .tag(MineSidebarDetail.downloads)
                .accessibilityIdentifier("mine.sidebar.downloads")
            }
            Section {
                sectionLink(.settings, icon: "gearshape.fill")
            }
        }
        .listStyle(.sidebar)
        // Keep the native tab accessibility probe inside the column; wrapping
        // the split view changes its navigation-bar safe-area layout.
        .messageUnreadTabAccessibility(count: messageUnreadWorkflow?.totalCount ?? 0)
        .navigationTitle(L10n.string("tab.mine"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.refreshProfile()
            await messageUnreadWorkflow?.refresh(force: true)
        }
        .accessibilityIdentifier("mine.sidebar.root")
    }

    private var rootSelection: Binding<MineSidebarDetail?> {
        Binding {
            guard navigation.section == nil else { return nil }
            switch navigation.detail {
            case .history: return .history(.all)
            case .likes: return .likes(.all)
            default: return navigation.detail
            }
        } set: { destination in
            guard let destination else { return }
            if (destination == .profile || destination == .messages), !viewModel.isLoggedIn {
                showLogin()
            } else {
                navigation.show(destination)
            }
        }
    }

    private func sectionLink(_ section: MineSidebarSection, icon: String) -> some View {
        Button {
            navigation.setSidebarPath([section])
        } label: {
            Label(section.title, systemImage: icon)
        }
        .tag(section == .history ? MineSidebarDetail.history(.all) :
            section == .likes ? MineSidebarDetail.likes(.all) : .settings(.category(.general)))
        .accessibilityIdentifier("mine.sidebar.\(section)")
    }

    @ViewBuilder
    private var profileLabel: some View {
        if let profile = viewModel.profile, viewModel.isLoggedIn {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MineAvatarView(profile: profile, avatarLoader: viewModel.profileAvatarLoader,
                        avatarReloadDate: viewModel.session.lastUpdatedAt)
                        .frame(width: 40, height: 40)
                    Text(profile.username.isEmpty ? L10n.string("mine.unknown_user") : profile.username)
                        .font(.headline)
                }
                MineCreditProgressView(progress: YamiboUserGroups.progress(for: profile))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                Text(L10n.string(viewModel.isLoggedIn ? "common.loading" : "mine.tap_to_login"))
            }
        }
    }

    @ViewBuilder
    private func categorySidebar(_ section: MineSidebarSection) -> some View {
        switch section {
        case .history, .likes:
            EmptyView()
        case .settings:
            SettingsSidebar(
                viewModel: settings.viewModel,
                selection: settingsSelection,
                accountManagementAvailable: settings.accountSwitcher != nil,
                isSigningOut: settings.isSigningOut,
                aboutTitle: settings.aboutTitle,
                showsCloseButton: false,
                onSignOut: { settings.pendingConfirmation = .signOut },
                onClose: { navigation.returnToRoot() },
                usesSelectionButtons: true,
                usesCompactLayout: horizontalSizeClass == .compact
            )
        }
    }

    private var historyFilter: BrowsingHistoryFilter {
        if case let .history(filter) = navigation.detail { filter } else { .all }
    }

    private var likesFilter: LikeWorkFilter {
        if case let .likes(filter) = navigation.detail { filter } else { .all }
    }

    private var settingsSelection: Binding<SettingsSidebarDestination?> {
        Binding {
            if case let .settings(destination) = navigation.detail { destination } else { nil }
        } set: { destination in
            guard settings.canNavigate, let destination else { return }
            navigation.show(.settings(destination))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch navigation.detail {
        case nil:
            Color(uiColor: .systemBackground)
                .accessibilityIdentifier("mine.detail.empty")
        case .profile:
            ForumDestinationScreen(destination: .userSpace(uid: nil, name: nil, section: .space, subPage: .profile), navigator: navigator)
        case .messages:
            ForumDestinationScreen(destination: .messageCenter(tab: .privateMessages), navigator: navigator)
        case .downloads:
            OfflineCacheQueueScreen(viewModel: viewModel.offlineQueue)
        case .history:
            BrowsingHistoryView(dependencies: settings.dependencies.library, appModel: appModel,
                categorySelection: Binding { historyFilter } set: { navigation.show(.history($0)) },
                onOpenThread: { url, title in navigator.pushThreadLink(url: url, title: title) })
        case .likes:
            LikeWorkListView(
                likeDependencies: likeDependencies,
                contentCoverStore: settings.dependencies.library.contentCoverStore,
                favoriteLibraryStore: settings.dependencies.library.localFavoriteLibraryStore,
                settingsStore: settings.dependencies.settingsStore,
                appModel: appModel,
                categorySelection: Binding { likesFilter } set: { navigation.show(.likes($0)) },
                onSelectionModeChange: { navigation.isSelectingLikes = $0 }
            )
            .navigationBarTitleDisplayMode(.inline)
        case let .settings(destination):
            SettingsSidebarDetail(destination: destination, dependencies: settings.dependencies,
                viewModel: settings.viewModel, peripheralInput: settings.peripheralInput,
                accountSwitcher: settings.accountSwitcher, onReset: settings.handleApplicationReset,
                usesCompactLayout: horizontalSizeClass == .compact)
                .id(destination)
        }
    }
}
