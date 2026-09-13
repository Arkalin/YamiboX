import SwiftUI
import YamiboXCore
import UIKit

public struct RootTabView: View {
    private let appModel: YamiboAppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var clipboardForumLinkPasteboardReader = ClipboardForumLinkPasteboardReader()
    @State private var appUpdateLaunchPrompter = AppUpdateLaunchPrompter()

    public init(appModel: YamiboAppModel, initialTab: AppTab = .forum) {
        self.appModel = appModel
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
                    ProgressView {
                        Text((appModel.bootstrapPhase ?? .loadingSession).startupMessage)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                }
            }
        }
        // Cross-fade from the bootstrap placeholder into the tab content
        // instead of hard-swapping frames.
        .animation(.easeInOut(duration: 0.25), value: isShowingBootstrapPlaceholder)
        .appTheme(.theme(for: appModel.appThemePreset))
        .task {
            await appModel.bootstrapIfNeeded()
        }
        .task {
            await appUpdateLaunchPrompter.checkForUpdateIfNeeded()
        }
        .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
            if appModel.scenePhaseDidChange(newPhase), newPhase == .active, oldPhase != newPhase {
                presentClipboardForumLinkPromptIfNeeded()
            }
        }
        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: !appModel.hasActiveReaderPresentation))
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
        appModel.bootstrapState == nil
    }

    private var content: some View {
        TabView(selection: selectedTabBinding) {
            ReadingHomeView(appModel: appModel)
                .id(appModel.accountGeneration)
                .tag(AppTab.home)
                .tabItem {
                    Label(L10n.string("tab.home"), systemImage: "house")
                }

            ForumNavigationHostView(
                dependencies: appModel.appContext.forumDependencies,
                appModel: appModel,
                theme: AppTheme.theme(for: appModel.appThemePreset).forumTheme
            )
                .id(appModel.accountGeneration)
                .tag(AppTab.forum)
                .tabItem {
                    Label(L10n.string("tab.forum"), systemImage: "text.bubble")
                }

            FavoritesNavigationHostView(dependencies: appModel.appContext.libraryDependencies, appModel: appModel)
                .id(appModel.accountGeneration)
                .tag(AppTab.favorites)
                .tabItem {
                    Label(L10n.string("tab.favorites"), systemImage: "heart.text.square")
                }

            MineHomeView(
                dependencies: appModel.appContext.accountDependencies,
                settingsDependencies: appModel.appContext.settingsDependencies,
                appModel: appModel,
                likeDependencies: appModel.appContext.likeLibraryDependencies
            )
                .tag(AppTab.mine)
                .tabItem {
                    Label(L10n.string("tab.mine"), systemImage: "person.crop.circle")
                        .accessibilityValue(MessageUnreadBadge.accessibilityValue(
                            for: appModel.appContext.messageUnreadWorkflow.totalCount
                        ))
                }
                .badge(MessageUnreadBadge.tabValue(for: appModel.appContext.messageUnreadWorkflow.totalCount))
        }
        .modifier(ReaderPresentationModifier(appModel: appModel))
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
                    ReaderSessionScreen(session: session, appModel: appModel)
                        .appTheme(AppTheme.theme(for: appModel.appThemePreset))
                        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: true))
                }
                // Reader edge pans belong to reading, not modal dismissal.
                .interactiveDismissDisabled()
            }
    }
}
