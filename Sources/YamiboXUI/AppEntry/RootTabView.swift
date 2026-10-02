import SwiftUI
import YamiboXCore
import UIKit

public struct RootTabView: View {
    private let appModel: YamiboAppModel
    private let launchScreenDeadline: ContinuousClock.Instant?

    @Environment(\.scenePhase) private var scenePhase
    @State private var clipboardForumLinkPasteboardReader = ClipboardForumLinkPasteboardReader()
    @State private var appUpdateLaunchPrompter = AppUpdateLaunchPrompter()
    @State private var hasCompletedMinimumLaunchDisplay = false

    public init(
        appModel: YamiboAppModel,
        initialTab: AppTab = .forum,
        launchScreenDeadline: ContinuousClock.Instant? = nil
    ) {
        self.appModel = appModel
        self.launchScreenDeadline = launchScreenDeadline
    }

    public var body: some View {
        ZStack {
            if appModel.ownsWebSessionPresentation {
                ForumWebSessionWebViewHost(
                    coordinator: appModel.webSessionCoordinator,
                    placement: .hidden
                )
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            Group {
                if isShowingBootstrapPlaceholder {
                    AppLaunchScreenView()
                } else {
                    content
                }
            }
        }
        .appTheme(.theme(for: appModel.appAppearanceSettings))
        .environment(\.readerToolbarStyle, appModel.readerToolbarStyle.effectiveStyle)
        .task {
            await appModel.bootstrapIfNeeded()
        }
        .task(id: launchScreenDeadline) {
            guard !hasCompletedMinimumLaunchDisplay else { return }
            // Carry the original deadline across storage and window preparation;
            // those stages count toward the minimum rather than adding to it.
            let deadline = launchScreenDeadline ?? ContinuousClock.now.advanced(by: .seconds(1.7))
            do {
                try await ContinuousClock().sleep(until: deadline)
                guard !Task.isCancelled else { return }
                hasCompletedMinimumLaunchDisplay = true
            } catch {
                // A cancelled view task must not publish a completed launch.
            }
        }
        .task {
            await appUpdateLaunchPrompter.checkForUpdateIfNeeded()
        }
        .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
            if appModel.scenePhaseDidChange(newPhase), newPhase == .active, oldPhase != newPhase,
               !isShowingBootstrapPlaceholder {
                presentClipboardForumLinkPromptIfNeeded()
            }
        }
        .onChange(of: isShowingBootstrapPlaceholder) { _, isShowing in
            if !isShowing, scenePhase == .active {
                presentClipboardForumLinkPromptIfNeeded()
            }
        }
        .modifier(ClipboardForumLinkPromptAlert(
            appModel: appModel,
            isActive: !isShowingBootstrapPlaceholder && !appModel.hasActiveReaderPresentation
        ))
        .readerTransitionOverlay(
            isPresented: appModel.isOpeningMangaReader,
            title: L10n.string("reader.switching_to_manga"),
            onCancel: appModel.cancelMangaReaderOpen
        )
        .failureAlert(
            L10n.string("manga.open.failed"),
            message: appModel.mangaOpenFailure?.summary,
            details: appModel.mangaOpenFailure,
            isPresented: Binding(
                get: { appModel.mangaOpenFailure != nil },
                set: { if !$0 { appModel.mangaOpenFailure = nil } }
            )
        ) {
            Button(L10n.string("common.ok")) { appModel.mangaOpenFailure = nil }
        }
        // Deferred rather than dropped while the placeholder or a restored
        // reader covers the tab content: the prompt state persists and the
        // alert presents once this surface is visible again.
        .modifier(AppUpdateLaunchPromptAlert(
            prompter: appUpdateLaunchPrompter,
            isActive: !isShowingBootstrapPlaceholder && !appModel.hasActiveReaderPresentation
        ))
        .fullScreenCover(item: webVerificationBinding) { _ in
            ForumWAFVerificationView(coordinator: appModel.webSessionCoordinator)
        }
        .environment(\.yamiboImagePipeline, appModel.imagePipeline)
    }

    private var isShowingBootstrapPlaceholder: Bool {
        appModel.bootstrapState == nil || !hasCompletedMinimumLaunchDisplay
    }

    private var content: some View {
        TabView(selection: selectedTabBinding) {
            ForEach(appModel.navigationSettings.tabs) { tab in
                tabContent(tab)
                    .tag(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(MessageUnreadBadge.tabValue(for: appModel.unreadCount(for: tab)))
            }
        }
        .modifier(ReaderPresentationModifier(appModel: appModel))
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .bookshelf:
            BookshelfView(
                libraryDependencies: appModel.appContext.libraryDependencies,
                accountDependencies: appModel.appContext.accountDependencies,
                accountSwitcher: appModel.appContext.accountSwitcher,
                forumDependencies: appModel.appContext.forumNavigationDependencies,
                appModel: appModel
            )
                .id(appModel.accountGeneration)
        case .forum:
            ForumNavigationHostView(
                dependencies: appModel.appContext.forumNavigationDependencies,
                appModel: appModel,
                theme: AppTheme.theme(for: appModel.appAppearanceSettings).forumTheme
            )
                .id(appModel.accountGeneration)
        case .favorites:
            FavoritesNavigationHostView(
                dependencies: appModel.appContext.libraryDependencies,
                forumDependencies: appModel.appContext.forumNavigationDependencies,
                appModel: appModel
            )
                .id(appModel.accountGeneration)
        case .mine:
            MineHomeView(
                dependencies: appModel.appContext.accountDependencies,
                forumDependencies: appModel.appContext.forumNavigationDependencies,
                accountSwitcher: appModel.appContext.accountSwitcher,
                settingsDependencies: appModel.appContext.settingsDependencies,
                appModel: appModel,
                likeDependencies: appModel.appContext.likeLibraryDependencies
            )
        case .messages, .history, .likes:
            OptionalTabRootView(tab: tab, appModel: appModel)
                .id(appModel.accountGeneration)
        }
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectTab($0) }
        )
    }

    private var webVerificationBinding: Binding<ForumWebSessionCoordinator.Presentation?> {
        Binding(
            get: { appModel.ownsWebSessionPresentation ? appModel.webSessionCoordinator.presentation : nil },
            set: { presentation in
                if presentation == nil, appModel.ownsWebSessionPresentation {
                    appModel.webSessionCoordinator.dismissPresentation()
                }
            }
        )
    }

    private func presentClipboardForumLinkPromptIfNeeded() {
        Task { @MainActor in
            guard let url = await clipboardForumLinkPasteboardReader.promptURL(from: UIPasteboard.general) else { return }
            appModel.presentClipboardForumLinkPrompt(url: url)
        }
    }
}

extension AppBootstrapPhase {
    var startupMessage: LocalizedStringResource {
        switch self {
        case .loadingSession: L10n.resource("app.startup.loading_session")
        case .loadingProfile: L10n.resource("app.startup.loading_profile")
        case .loadingSettings: L10n.resource("app.startup.loading_settings")
        case .loadingFavorites: L10n.resource("app.startup.loading_favorites")
        case .synchronizingWebDAV: L10n.resource("app.startup.synchronizing_webdav")
        case .loadingReadingPosition: L10n.resource("app.startup.loading_reading_position")
        }
    }
}

struct ClipboardForumLinkPromptAlert: ViewModifier {
    let appModel: YamiboAppModel
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .alert(
                L10n.string("clipboard_forum_link.title"),
                isPresented: promptIsPresented,
                presenting: isActive ? appModel.clipboardForumLinkPrompt : nil
            ) { prompt in
                Button(L10n.string("clipboard_forum_link.open")) {
                    appModel.confirmClipboardForumLinkPrompt(prompt)
                }
                Button(L10n.string("common.cancel"), role: .cancel) {
                    appModel.dismissClipboardForumLinkPrompt()
                }
            } message: { prompt in
                Text(prompt.url.absoluteString)
            }
    }

    private var promptIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && appModel.clipboardForumLinkPrompt != nil },
            set: { isPresented in
                if !isPresented, isActive {
                    appModel.dismissClipboardForumLinkPrompt()
                }
            }
        )
    }
}

private struct AppUpdateLaunchPromptAlert: ViewModifier {
    let prompter: AppUpdateLaunchPrompter
    let isActive: Bool

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert(
                prompter.prompt?.title ?? "",
                isPresented: promptIsPresented,
                presenting: isActive ? prompter.prompt : nil
            ) { prompt in
                Button(L10n.string("app_update.open_download")) {
                    openURL(prompt.downloadURL)
                }
                Button(L10n.string("app_update.copy_source")) {
                    UIPasteboard.general.string = AppUpdateChecker.defaultSourceURL.absoluteString
                }
                Button(L10n.string("app_update.skip_version")) {
                    prompter.skipPromptedVersion()
                }
                Button(L10n.string("app_update.later"), role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
    }

    private var promptIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { isActive && prompter.prompt != nil },
            clearOnDismiss: { prompter.dismissPrompt() }
        )
    }
}

private struct ReaderPresentationModifier: ViewModifier {
    let appModel: YamiboAppModel

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: Binding(
                get: { appModel.presentedReaderSession },
                set: { if $0 == nil { appModel.dismissPresentedReaderSession() } }
            ), onDismiss: appModel.readerCoverDidDismiss) { session in
                BookOpeningDestination(source: session.bookOpeningTransition) {
                    ReaderSessionScreen(
                        session: session,
                        dependencies: appModel.appContext.forumNavigationDependencies,
                        appModel: appModel
                    )
                        .appTheme(AppTheme.theme(for: appModel.appAppearanceSettings))
                        .environment(\.readerToolbarStyle, appModel.readerToolbarStyle.effectiveStyle)
                        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: true))
                }
                // Reader edge pans belong to reading, not modal dismissal.
                .interactiveDismissDisabled()
            }
    }
}
