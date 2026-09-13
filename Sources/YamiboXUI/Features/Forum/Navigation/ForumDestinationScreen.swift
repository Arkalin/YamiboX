import SwiftUI
import YamiboXCore

struct ForumDestinationScreen: View {
    @Environment(\.forumBrowserSourceIsList) private var fromBrowserList
    let destination: ForumDestination
    let navigator: ForumDestinationNavigator

    private var dependencies: ForumDependencies { navigator.dependencies }

    var body: some View {
        switch destination {
        case .home:
            ForumHomeDestination(navigator: navigator)
        case let .board(fid, title, page):
            ForumBoardView(
                model: ForumBoardViewModel(
                    fid: fid,
                    title: title,
                    initialPage: page ?? 1,
                    dependencies: dependencies
                ),
                refreshRevision: navigator.appModel.forumContentRefresh.boardRevision(fid),
                onSubBoardTap: { navigator.openBoard($0, fromBrowserList: fromBrowserList) },
                onPinnedTap: { navigator.openPinnedItem($0, containingFid: fid, fromBrowserList: fromBrowserList) },
                onThreadTap: { navigator.openThread($0, containingFid: fid, fromBrowserList: fromBrowserList) },
                onThreadReaderOverrideTap: navigator.threadReaderOverrideHandler(containingFid: fid, fromBrowserList: fromBrowserList),
                onPinnedReaderOverrideTap: navigator.pinnedReaderOverrideHandler(containingFid: fid, fromBrowserList: fromBrowserList),
                onAuthorTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onSearchTap: {
                    navigator.openSearch(fid: fid, fromBrowserList: fromBrowserList)
                },
                onPostThreadTap: {
                    navigator.openPostThreadComposer(fid: fid)
                }
            )
            .forumNavigationBarStyle()
        case let .search(fid):
            ForumSearchView(
                model: ForumSearchViewModel(forumID: fid, dependencies: dependencies),
                onThreadTap: { navigator.openThread($0, containingFid: fid, fromBrowserList: fromBrowserList) },
                onAuthorTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLSubmit: {
                    navigator.route($0, source: .external, fromBrowserList: fromBrowserList)
                }
            )
            .forumNavigationBarStyle()
        case let .userSpace(uid, name, section, subPage):
            UserSpaceView(
                model: UserSpaceViewModel(
                    uid: uid,
                    titleHint: name,
                    initialSection: section,
                    initialSubPage: subPage,
                    dependencies: dependencies
                ),
                refreshRevision: navigator.appModel.forumContentRefresh.userSpaceRevision,
                onThreadTap: { navigator.openThread($0, title: $1, containingFid: nil) },
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onSectionTap: { navigator.openUserSpaceSection(uid: $0, name: $1, section: $2, subPage: $3) },
                onBlogTap: { navigator.openBlog($0) },
                onPrivateMessageTap: { navigator.openPrivateMessage(uid: $0, name: $1) },
                onMessageCenterTap: { navigator.openMessageCenter(tab: $0) },
                onCreditLogTap: { navigator.openCreditLog() },
                onWebTap: {
                    navigator.route($0, source: .external)
                }
            )
            .forumNavigationBarStyle()
        case .creditLog:
            CreditLogView(
                model: CreditLogViewModel(dependencies: dependencies),
                onURLTap: { navigator.route($0, source: .external) }
            )
            .id(navigator.appModel.accountGeneration)
            .forumNavigationBarStyle()
        case let .messageCenter(tab):
            MessageCenterView(
                model: MessageCenterViewModel(initialTab: tab, dependencies: dependencies),
                onPrivateMessageTap: { navigator.openPrivateMessage(uid: $0, name: $1) },
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLTap: { navigator.route($0, source: .external) }
            )
            .forumNavigationBarStyle()
        case let .privateMessage(uid, name):
            PrivateMessageView(
                model: PrivateMessageViewModel(
                    uid: uid,
                    titleHint: name,
                    dependencies: dependencies
                )
            )
            .forumNavigationBarStyle()
        case let .blog(blogID, uid, title):
            BlogReaderView(
                model: BlogReaderViewModel(blogID: blogID, uid: uid, titleHint: title, dependencies: dependencies),
                refreshRevision: navigator.appModel.forumContentRefresh.blogRevision(blogID),
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onWebTap: {
                    navigator.route($0, source: .external)
                }
            )
            .forumNavigationBarStyle()
        case let .novelDetail(context):
            detailScreen(.novel(context))
        case let .mangaDetail(context):
            detailScreen(.manga(context))
        case let .threadReader(context):
            ForumThreadDestinationView(context: context, navigator: navigator)
            .forumNavigationBarStyle()
        case let .threadLink(url, title, containingFid, authorID, isDiscussionView):
            ForumThreadLinkScreen(
                url: url,
                title: title,
                containingFid: containingFid,
                authorID: authorID,
                isDiscussionView: isDiscussionView,
                navigator: navigator
            )
            .forumNavigationBarStyle()
        case let .web(url), let .postEditor(url), let .blogEditor(url), let .actionForm(url):
            ForumURLDestinationView(url: url, navigator: navigator)
            .forumNavigationBarStyle()
        case let .webFallback(url):
            ForumURLDestinationView(url: url, navigator: navigator, fallback: true)
                .forumNavigationBarStyle()
        }
    }

    private func detailScreen(_ destination: ContentDetailDestination) -> some View {
        ContentDetailScreen(
            destination: destination,
            novelDependencies: dependencies.novelDetailDependencies,
            mangaDependencies: dependencies.mangaDetailDependencies
        ) { action in
            switch action {
            case let .readNovel(context, transition): navigator.appModel.presentNovelReader(context, bookOpeningTransition: transition)
            case let .readManga(context, transition): navigator.appModel.requestMangaReader(context, bookOpeningTransition: transition)
            case let .author(uid, name): navigator.openUserSpace(uid: uid, name: name)
            case let .discussion(context): navigator.push(.threadReader(context))
            }
        }
    }
}

/// Resolves a thread URL in place (native thread reader intent) and then
/// renders the thread reader, keeping the resolution visible where the user
/// tapped instead of blocking the navigation on a network round-trip. Used as
/// the reader overlay's root and for `.threadLink` pushes.
struct ForumThreadLinkScreen: View {
    let url: URL
    let title: String?
    let containingFid: String?
    let authorID: String?
    let isDiscussionView: Bool
    let navigator: ForumDestinationNavigator

    @State private var resolution: Resolution = .resolving

    private enum Resolution {
        case resolving
        case thread(ThreadNovelLaunchContext)
        case web(URL)
        case failed(LoadFailureDetails)
    }

    var body: some View {
        content
            .task {
                await resolveIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch resolution {
        case .resolving:
            ContentLoadingView(
                text: L10n.string("forum.thread_link.loading"),
                layout: .fillsPage
            )
            .navigationTitle(title ?? L10n.string("forum.default_title"))
            .yamiboInlineNavigationTitleDisplayMode()
        case let .thread(context):
            ForumThreadDestinationView(context: context, navigator: navigator)
        case let .web(webURL):
            ForumURLDestinationView(url: webURL, navigator: navigator, fallback: true)
        case let .failed(details):
            LoadFailureView(message: details.summary, details: details, prominentRetry: true) {
                resolution = .resolving
                Task {
                    await resolveIfNeeded()
                }
            }
            .padding()
            .forumPageBackground()
        }
    }

    private func resolveIfNeeded() async {
        guard case .resolving = resolution else { return }
        let resolver = await navigator.dependencies.makeThreadRouteResolver()
        do {
            let target = try await resolver.resolve(
                YamiboThreadRouteRequest(
                    threadURL: url,
                    title: title,
                    authorID: authorID,
                    intent: .nativeThreadReader,
                    tapContext: YamiboThreadTapContext(containingFid: containingFid)
                )
            )
            switch target {
            case let .thread(payload), let .novel(payload), let .manga(payload), let .mangaDirect(payload):
                guard !payload.thread.tid.isEmpty else {
                    resolution = .web(url)
                    return
                }
                resolution = .thread(
                    navigator.threadLinkLaunchContext(for: payload, isDiscussionView: isDiscussionView)
                )
            case let .webFallback(fallbackURL):
                resolution = .web(fallbackURL)
            }
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            resolution = .failed(LoadFailureDetails(error: error, requestContext: url.absoluteString))
        }
    }
}

private struct ForumHomeDestination: View {
    @Environment(\.forumBrowserSourceIsList) private var fromBrowserList
    let navigator: ForumDestinationNavigator
    @State private var model: ForumHomeViewModel

    init(navigator: ForumDestinationNavigator) {
        self.navigator = navigator
        _model = State(wrappedValue: ForumHomeViewModel(dependencies: navigator.dependencies))
    }

    var body: some View {
        ForumHomeView(
            model: model,
            onBoardTap: { navigator.openBoard($0, fromBrowserList: fromBrowserList) },
            onCarouselTap: { navigator.openCarouselItem($0, fromBrowserList: fromBrowserList) }
        )
            .navigationTitle(L10n.string("forum.default_title"))
            .yamiboInlineNavigationTitleDisplayMode()
            .forumNavigationBarStyle()
            .task { await model.load() }
    }
}

private struct ForumURLDestinationView: View {
    let url: URL
    let navigator: ForumDestinationNavigator
    var fallback = false
    @State private var fallbackURL: URL?

    private var isNativeForm: Bool {
        switch ForumRouteResolver.resolve(url: url) {
        case .postEditor, .blogEditor, .actionForm: true
        default: false
        }
    }

    var body: some View {
        let accountGeneration = navigator.appModel.accountGeneration
        if isNativeForm, !fallback, fallbackURL == nil {
            ForumPageScreen(model: ForumPageSession(
                url: url, dependencies: navigator.dependencies,
                onSubmissionAccepted: { change in
                    guard accountGeneration == navigator.appModel.accountGeneration else { return }
                    navigator.appModel.forumContentRefresh.record(change)
                }
            ),
                onSubmissionSucceeded: { navigator.transientFeedback = $0 },
                onNavigationResult: { result in
                    guard accountGeneration == navigator.appModel.accountGeneration else { return }
                    switch result {
                    case let .webFallback(url): fallbackURL = url
                    case let .nativeRedirect(url):
                        if !navigator.path.isEmpty { navigator.path.removeLast() }
                        navigator.route(url, source: .external)
                    case .page: break
                    }
                }) {
                navigator.route($0, source: .external)
            }
            .id(accountGeneration)
        } else {
            ForumBrowserView(
                url: fallbackURL ?? url, sessionStore: navigator.dependencies.sessionStore,
                appModel: navigator.appModel, listensToForumNavigationRequest: false,
                nativeFallback: fallback || fallbackURL != nil,
                onNativeNavigation: {
                    guard accountGeneration == navigator.appModel.accountGeneration else { return }
                    navigator.route($0, source: .external)
                }
            )
            .id(navigator.appModel.accountGeneration)
        }
    }
}

private struct ForumThreadDestinationView: View {
    let context: ThreadNovelLaunchContext
    let navigator: ForumDestinationNavigator

    var body: some View {
        if navigator.mode == .readerOverlay {
            ForumThreadReaderView(
                model: ForumThreadReaderViewModel(context: context, dependencies: navigator.dependencies),
                submissionChange: navigator.appModel.forumContentRefresh.threadChange(context.thread.tid),
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLTap: { navigator.route($0, source: .external) }
            )
        } else {
            ReaderSessionDestinationView(context: context, navigator: navigator)
        }
    }
}
