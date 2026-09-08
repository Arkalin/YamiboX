import SwiftUI
import YamiboXCore

struct ForumDestinationScreen: View {
    let destination: ForumDestination
    let navigator: ForumDestinationNavigator

    private var dependencies: ForumDependencies { navigator.dependencies }

    var body: some View {
        switch destination {
        case let .board(fid, title, page):
            ForumBoardView(
                model: ForumBoardViewModel(
                    fid: fid,
                    title: title,
                    initialPage: page ?? 1,
                    dependencies: dependencies
                ),
                onSubBoardTap: { navigator.openBoard($0) },
                onPinnedTap: { navigator.openPinnedItem($0, containingFid: fid) },
                onThreadTap: { navigator.openThread($0, containingFid: fid) },
                onThreadReaderOverrideTap: navigator.threadReaderOverrideHandler(containingFid: fid),
                onPinnedReaderOverrideTap: navigator.pinnedReaderOverrideHandler(containingFid: fid),
                onAuthorTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onSearchTap: {
                    navigator.push(.search(fid: fid))
                },
                onPostThreadTap: {
                    navigator.openPostThreadFallback(fid: fid)
                }
            )
            .forumNavigationBarStyle()
        case let .search(fid):
            ForumSearchView(
                model: ForumSearchViewModel(forumID: fid, dependencies: dependencies),
                onThreadTap: { navigator.openThread($0, containingFid: fid) },
                onAuthorTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLSubmit: {
                    navigator.route($0, source: .external)
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
                onThreadTap: { navigator.openThread($0, title: $1, containingFid: nil) },
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onSectionTap: { navigator.openUserSpaceSection(uid: $0, name: $1, section: $2, subPage: $3) },
                onBlogTap: { navigator.openBlog($0) },
                onPrivateMessageTap: { navigator.openPrivateMessage(uid: $0, name: $1) },
                onMessageCenterTap: { navigator.openMessageCenter(tab: $0) },
                onWebTap: {
                    navigator.push(.web($0))
                }
            )
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
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onWebTap: {
                    navigator.push(.web($0))
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
        case let .web(url):
            ForumBrowserView(
                url: url,
                sessionStore: dependencies.sessionStore,
                appModel: navigator.appModel,
                listensToForumNavigationRequest: false
            )
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
            case let .readNovel(context): navigator.appModel.presentNovelReader(context)
            case let .readManga(context): navigator.appModel.requestMangaReader(context)
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
            ForumBrowserView(
                url: webURL,
                sessionStore: navigator.dependencies.sessionStore,
                appModel: navigator.appModel,
                listensToForumNavigationRequest: false
            )
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

private struct ForumThreadDestinationView: View {
    let context: ThreadNovelLaunchContext
    let navigator: ForumDestinationNavigator

    var body: some View {
        if navigator.mode == .readerOverlay {
            ForumThreadReaderView(
                model: ForumThreadReaderViewModel(context: context, dependencies: navigator.dependencies),
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLTap: { navigator.route($0, source: .external) }
            )
        } else {
            ReaderSessionDestinationView(context: context, navigator: navigator)
        }
    }
}
