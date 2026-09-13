import SwiftUI
import YamiboXCore

struct ReaderSessionScreen: View {
    let session: ReaderSession
    let appModel: YamiboAppModel
    @State private var navigator: ForumDestinationNavigator

    init(session: ReaderSession, appModel: YamiboAppModel) {
        self.session = session
        self.appModel = appModel
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumDependencies,
            appModel: appModel,
            mode: .contentBrowser
        ))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator) {
            ReaderSessionContentView(session: session, navigator: navigator, isFullScreenRoot: true)
        }
        .onChange(of: session.contentID) { _, _ in
            navigator.path = []
        }
        .forumTheme(AppTheme.theme(for: appModel.appThemePreset).forumTheme)
    }
}

/// The thread stays in its navigation column while reading opens over the window.
struct ReaderSessionDestinationView: View {
    @State private var session: ReaderSession
    let navigator: ForumDestinationNavigator

    init(context: ThreadNovelLaunchContext, navigator: ForumDestinationNavigator) {
        self.navigator = navigator
        _session = State(initialValue: navigator.appModel.makeReaderSession(
            content: .thread(context), presentation: .embeddedThread
        ))
    }

    var body: some View {
        ReaderSessionContentView(session: session, navigator: navigator, isFullScreenRoot: false)
    }
}

private struct ReaderSessionContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forumKeepsTabBarVisible) private var keepsTabBarVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ReaderSession
    let navigator: ForumDestinationNavigator
    let isFullScreenRoot: Bool

    private var appModel: YamiboAppModel { navigator.appModel }
    private var isReader: Bool { session.content.resumeRoute != nil }

    var body: some View {
        ZStack {
            content
                // Only the mode surface transitions; reader layout and restored
                // scroll positions must settle without inheriting its animation.
                .transaction { $0.animation = nil }
                .id(session.contentID)
                .transition(modeTransition)
                .zIndex(1)
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isReader)
        .readerTransitionOverlay(isPresented: session.isSwitching, title: session.switchingTitle, onCancel: session.cancelSwitch)
        .toolbar(!isReader && keepsTabBarVisible ? .visible : .hidden, for: .tabBar)
        .navigationBarBackButtonHidden(isReader)
        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: !isFullScreenRoot && isReader))
        .onAppear { session.activate() }
        .onDisappear {
            if !isFullScreenRoot { session.deactivate() }
        }
        .onChange(of: session.isClosed) { _, closed in
            if closed && !isFullScreenRoot { dismiss() }
        }
        .failureToast(
            message: session.switchFailure?.summary,
            details: session.switchFailure
        ) {
            session.switchFailure = nil
        }
    }

    private var modeTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: isReader ? 8 : -8))
    }

    @ViewBuilder
    private var content: some View {
        let contentID = session.contentID
        switch session.content {
        case let .novel(context):
            NovelReaderView(
                context: context,
                dependencies: appModel.appContext.novelReaderDependencies,
                appModel: appModel,
                onClose: { session.close() },
                onOpenOriginalPost: { url, context in
                    guard session.contentID == contentID else { return false }
                    return await session.openOriginalPost(url: url, resumeRoute: .novel(context))
                },
                onResumeRouteChange: { route in session.updateResumeRoute(route, contentID: contentID) }
            )
            .id(contentID)
            .ignoresSafeArea()
        case let .manga(context):
            MangaReaderView(
                context: context,
                dependencies: appModel.appContext.mangaReaderDependencies,
                appModel: appModel,
                initialProjection: session.preparedMangaProjection,
                onClose: { session.close() },
                onOpenOriginalPost: { url, context in
                    guard session.contentID == contentID else { return false }
                    return await session.openOriginalPost(url: url, resumeRoute: .manga(context))
                },
                onResumeRouteChange: { route in session.updateResumeRoute(route, contentID: contentID) }
            )
            .id(contentID)
            .ignoresSafeArea()
        case let .thread(context):
            let model = session.threadModel(for: context, dependencies: navigator.dependencies)
            ForumThreadReaderView(
                model: model,
                submissionChange: appModel.forumContentRefresh.threadChange(context.thread.tid),
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLTap: { navigator.route($0, source: .external) },
                onReaderModeSwitch: { mode in Task { await session.openReader(mode, from: model) } },
                isSwitchingReaderMode: session.isSwitching
            )
            .id(contentID)
            .forumNavigationBarStyle()
            .toolbar {
                if isFullScreenRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        ReaderToolbarIconButton(
                            systemName: "xmark",
                            title: L10n.string("common.done"),
                            action: { session.close() }
                        )
                    }
                }
            }
        }
    }
}
