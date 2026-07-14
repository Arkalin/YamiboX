import SwiftUI
import YamiboXCore

/// Path owner + route helpers shared by the forum tab and reader-overlay
/// forum stacks. Owns everything `ForumDestinationScreen` needs to wire its
/// destination views, so hosts only decide the root content and the mode.
@MainActor
@Observable
final class ForumDestinationNavigator {
    var path: [ForumDestination] = []
    var actionErrorMessage: String?

    @ObservationIgnored let dependencies: ForumDependencies
    @ObservationIgnored let appModel: YamiboAppModel
    @ObservationIgnored let mode: ForumNavigationMode
    /// The reader session's own thread IDs (the work plus, for smart manga,
    /// its chapter threads). Any thread opened inside the overlay that
    /// resolves to one of these is still the work's discussion companion, so
    /// it must keep `isDiscussionView: true` — otherwise its plain-thread
    /// history row would absorb the work's main-form row (browsing-history
    /// decision #14 / review finding P1-B: rows upsert by tid across kinds).
    @ObservationIgnored let discussionWorkTIDs: Set<String>

    init(
        dependencies: ForumDependencies,
        appModel: YamiboAppModel,
        mode: ForumNavigationMode,
        discussionWorkTIDs: Set<String> = []
    ) {
        self.dependencies = dependencies
        self.appModel = appModel
        self.mode = mode
        self.discussionWorkTIDs = discussionWorkTIDs
    }

    func threadLinkLaunchContext(
        for payload: YamiboThreadRoutePayload,
        isDiscussionView: Bool
    ) -> ThreadNovelLaunchContext {
        ThreadNovelLaunchContext(
            thread: payload.thread,
            title: payload.title,
            initialPage: payload.initialPage,
            targetPostID: payload.targetPostID,
            authorID: payload.authorID,
            isDiscussionView: isDiscussionView || discussionWorkTIDs.contains(payload.thread.tid)
        )
    }

    func push(_ destination: ForumDestination) {
        path.append(destination)
    }

    func route(_ url: URL, source: ForumNavigationSource, title: String? = nil) {
        switch ForumRouteResolver.resolve(url: url, source: source) {
        case .home:
            switch mode {
            case .forumTab:
                path = []
            case .readerOverlay:
                // There is no forum home inside an overlay stack, and popping
                // to its root would land on the original post instead — show
                // the web home so the link still leads somewhere sensible.
                push(.web(url))
            }
        case let .board(fid, title, page):
            push(.board(fid: fid, title: title, page: page))
        case let .thread(threadURL):
            openThread(
                threadURL,
                title: title,
                containingFid: nil,
                intent: source == .readerOrigin || source == .readerDiscussion ? .nativeThreadReader : .contentRoute,
                isDiscussionView: source == .readerDiscussion
            )
        case let .userSpace(uid, name):
            push(.userSpace(uid: uid, name: name, section: .space, subPage: .profile))
        case let .messageCenter(tab):
            push(.messageCenter(tab: tab))
        case let .privateMessage(uid, name):
            push(.privateMessage(uid: uid, name: name))
        case let .blog(blogID, uid, title):
            push(.blog(blogID: blogID, uid: uid, title: title))
        case let .web(url):
            push(.web(url))
        }
    }

    func openBoard(_ board: ForumBoardSummary) {
        push(.board(fid: board.fid, title: board.name, page: nil))
    }

    func openCarouselItem(_ item: ForumHomeCarouselItem) {
        if item.isThreadTarget {
            openThread(item.targetURL, title: nil, containingFid: nil)
        }
    }

    func openThread(
        _ url: URL,
        title: String?,
        containingFid: String?,
        intent: YamiboThreadRouteIntent = .contentRoute,
        isDiscussionView: Bool = false
    ) {
        if mode == .readerOverlay {
            pushThreadLink(url: url, title: title, containingFid: containingFid, isDiscussionView: isDiscussionView)
            return
        }
        Task {
            do {
                let resolver = await dependencies.makeThreadRouteResolver()
                let target = try await resolver.resolve(
                    YamiboThreadRouteRequest(
                        threadURL: url,
                        title: title,
                        intent: intent,
                        tapContext: YamiboThreadTapContext(containingFid: containingFid)
                    )
                )
                openYamiboThreadRouteTarget(target, isDiscussionView: isDiscussionView)
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    func openThread(_ thread: ForumThreadSummary, containingFid: String?) {
        if mode == .readerOverlay {
            pushThreadLink(
                url: thread.url,
                title: thread.title,
                containingFid: containingFid ?? thread.fid,
                authorID: thread.authorID
            )
            return
        }
        Task {
            do {
                let resolver = await dependencies.makeThreadRouteResolver()
                let target = try await resolver.resolve(
                    YamiboThreadRouteRequest(
                        threadURL: thread.url,
                        threadID: thread.tid,
                        title: thread.title,
                        authorID: thread.authorID,
                        threadFid: thread.fid,
                        tapContext: YamiboThreadTapContext(containingFid: containingFid)
                    )
                )
                openYamiboThreadRouteTarget(target)
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    func pushThreadLink(
        url: URL,
        title: String?,
        containingFid: String? = nil,
        authorID: String? = nil,
        isDiscussionView: Bool = false
    ) {
        push(.threadLink(
            url: url,
            title: title,
            containingFid: containingFid,
            authorID: authorID,
            isDiscussionView: isDiscussionView
        ))
    }

    func openUserSpace(uid: String, name: String?) {
        push(.userSpace(uid: uid, name: name, section: .space, subPage: .profile))
    }

    func openUserSpaceSection(uid: String?, name: String?, section: UserSpaceSection, subPage: UserSpaceSubPage) {
        push(.userSpace(uid: uid, name: name, section: section, subPage: subPage))
    }

    func openBlog(_ blog: UserSpaceBlogSummary) {
        push(.blog(blogID: blog.blogID, uid: blog.authorID, title: blog.title))
    }

    func openPrivateMessage(uid: String, name: String?) {
        push(.privateMessage(uid: uid, name: name))
    }

    func openMessageCenter(tab: MessageCenterTab) {
        push(.messageCenter(tab: tab))
    }

    func openPinnedItem(_ item: ForumPinnedItem, containingFid: String?) {
        if item.threadID != nil {
            openThread(item.url, title: item.title, containingFid: containingFid)
        } else {
            push(.web(item.url))
        }
    }

    func openPostThreadFallback(fid: String) {
        var components = URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/forum.php"
        components.queryItems = [
            .init(name: "mod", value: "post"),
            .init(name: "action", value: "newthread"),
            .init(name: "fid", value: fid),
            .init(name: "mobile", value: "2")
        ]
        if let url = components.url {
            push(.web(url))
        }
    }

    private func openYamiboThreadRouteTarget(_ target: YamiboThreadRouteTarget, isDiscussionView: Bool = false) {
        switch target {
        case let .novel(payload):
            let context = NovelDetailLaunchContext(
                thread: payload.thread,
                title: payload.title,
                authorID: payload.authorID
            )
            push(.novelDetail(context))
        case let .manga(payload):
            let cleanBookName = MangaTitleCleaner.cleanBookName(payload.title)
            let context = MangaDetailLaunchContext(
                thread: payload.thread,
                title: cleanBookName,
                focusedChapterTID: payload.thread.tid,
                directoryNameHint: cleanBookName
            )
            push(.mangaDetail(context))
        case let .mangaDirect(payload):
            // Board's Smart Comic Mode is off (decision #2/#12): open the
            // manga reader directly for this one thread instead of pushing
            // `ForumMangaDetailView`, using the same full-screen presentation
            // path as favorites/likes/the chapter picker
            // (`appModel.presentMangaReader`) rather than a NavigationStack
            // destination. No directory concept applies here — this thread
            // is treated exactly like a normal thread (total principle,
            // decision #2), just rendered with the manga reader — so the
            // title is used as-is (no `cleanBookName` cleanup) and page 0 is
            // the only sensible start (no resume, matching
            // `ForumMangaDetailViewModel.launchContext(for chapter:)`'s
            // existing convention of never passing `initialPage`).
            let context = MangaLaunchContext(
                originalThreadID: payload.thread.tid,
                chapterTID: payload.thread.tid,
                displayTitle: payload.title,
                source: .forum,
                isSmartModeEnabled: false,
                forumID: payload.thread.fid
            )
            appModel.presentMangaReader(context)
        case let .thread(payload):
            let context = ThreadNovelLaunchContext(
                thread: payload.thread,
                title: payload.title,
                initialPage: payload.initialPage,
                targetPostID: payload.targetPostID,
                authorID: payload.authorID,
                isDiscussionView: isDiscussionView
            )
            push(.threadReader(context))
        case let .webFallback(url):
            push(.web(url))
        }
    }
}
