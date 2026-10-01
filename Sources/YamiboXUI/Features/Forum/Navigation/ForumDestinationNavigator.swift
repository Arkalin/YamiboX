import SwiftUI
import YamiboXCore

/// Path owner + route helpers shared by the forum tab and reader-overlay
/// forum stacks. Receives explicit service packages and narrow navigation
/// actions; application-backed view assembly remains in destination hosts.
@MainActor
@Observable
final class ForumDestinationNavigator {
    var path: [ForumDestination] = [] {
        didSet {
            if oldValue != path {
                cancelThreadOpen()
                pathRevision = UUID()
                let retained = Set(path.compactMap { destination -> ThreadNovelLaunchContext? in
                    if case let .threadReader(context) = destination { return context }
                    return nil
                })
                preloadedThreadPages = preloadedThreadPages.filter { retained.contains($0.key) }
            }
        }
    }
    private(set) var browserDetailRevision = UUID()
    private(set) var browserUsesSplitNavigation: Bool
    var actionErrorMessage: String? {
        didSet { actionErrorDetails = nil }
    }
    var actionErrorDetails: LoadFailureDetails?
    var transientFeedback: TransientFeedback?
    private(set) var isOpeningContent = false
    @ObservationIgnored private var contentOpenTask: Task<Void, Never>?
    @ObservationIgnored private var threadOpenTask: Task<Void, Never>?
    @ObservationIgnored private var preloadedThreadPages: [ThreadNovelLaunchContext: (generation: UUID, page: ForumThreadPage)] = [:]

    func preloadedPage(for context: ThreadNovelLaunchContext) -> ForumThreadPage? {
        guard let seed = preloadedThreadPages[context], seed.generation == actions.accountGeneration() else { return nil }
        return seed.page
    }

    @ObservationIgnored let dependencies: ForumNavigationDependencies
    @ObservationIgnored private let actions: ForumNavigationActions
    @ObservationIgnored let mode: ForumNavigationMode
    @ObservationIgnored let usesSplitNavigation: Bool
    @ObservationIgnored private var browserOpenID: UUID?
    @ObservationIgnored private var pathRevision = UUID()
    @ObservationIgnored private var browserLayoutRevision = UUID()
    /// The reader session's own thread IDs (the work plus, for smart manga,
    /// its chapter threads). Any thread opened inside the overlay that
    /// resolves to one of these is still the work's discussion companion, so
    /// it must keep `isDiscussionView: true` — otherwise its plain-thread
    /// history row would absorb the work's main-form row (browsing-history
    /// decision #14 / review finding P1-B: rows upsert by tid across kinds).
    @ObservationIgnored let discussionWorkTIDs: Set<String>

    init(
        dependencies: ForumNavigationDependencies,
        actions: ForumNavigationActions,
        mode: ForumNavigationMode,
        discussionWorkTIDs: Set<String> = [],
        usesSplitNavigation: Bool = false
    ) {
        self.dependencies = dependencies
        self.actions = actions
        self.mode = mode
        self.discussionWorkTIDs = discussionWorkTIDs
        self.usesSplitNavigation = usesSplitNavigation
        self.browserUsesSplitNavigation = usesSplitNavigation
    }

    func updateBrowserLayout(isRegular: Bool) {
        let split = usesSplitNavigation && isRegular
        guard split != browserUsesSplitNavigation else { return }
        // Invalidate old bindings before SwiftUI tears down either container.
        browserLayoutRevision = UUID()
        browserUsesSplitNavigation = split
    }

    enum BrowserPathColumn {
        case stack, list, detail
    }

    func browserPathBinding(for column: BrowserPathColumn) -> Binding<[ForumDestination]> {
        // Observe the route while building the binding, not only inside its getter.
        let sourcePath = path
        let layoutRevision = browserLayoutRevision
        let routeRevision = pathRevision
        return Binding(
            get: {
                switch column {
                case .stack: self.path
                case .list: self.browserListPath
                case .detail: Array(self.browserDetailPath.dropFirst())
                }
            },
            set: { value in
                guard self.browserLayoutRevision == layoutRevision,
                      self.pathRevision == routeRevision, self.path == sourcePath else { return }
                switch column {
                case .stack:
                    self.path = value
                case .list:
                    if value != self.browserListPath { self.path = value }
                case .detail:
                    self.path = self.browserListPath + Array(self.browserDetailPath.prefix(1)) + value
                }
            }
        )
    }

    var browserListPath: [ForumDestination] {
        Array(path.prefix { destination in
            switch destination {
            case .home, .board, .search, .tag: true
            default: false
            }
        })
    }

    var browserDetailPath: [ForumDestination] { Array(path.dropFirst(browserListPath.count)) }

    var selectedBrowserThreadID: String? {
        // Auxiliary pages retain the latest thread's context, not the first
        // thread opened from the sidebar.
        for destination in browserDetailPath.reversed() {
            switch destination {
            case let .threadReader(context): return context.thread.tid
            case let .novelDetail(context): return context.thread.tid
            case let .mangaDetail(context): return context.thread.tid
            default: continue
            }
        }
        return nil
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
        if case let .web(url) = destination, ForumRouteResolver.supportsNativePage(url) {
            route(url, source: .external)
            return
        }
        path.append(destination)
        if !browserDetailPath.isEmpty { browserDetailRevision = UUID() }
    }

    func readerSourceHandoff() -> @MainActor () -> Void {
        let sourcePath = path
        let sourceRevision = pathRevision
        return { [weak self] in
            guard let self, !sourcePath.isEmpty,
                  self.pathRevision == sourceRevision, self.path == sourcePath else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { _ = self.path.removeLast() }
        }
    }

    func route(_ url: URL, source: ForumNavigationSource, title: String? = nil, fromBrowserList: Bool = false) {
        cancelThreadOpen()
        if fromBrowserList && browserUsesSplitNavigation { path = browserListPath }
        switch ForumRouteResolver.resolve(url: url, source: source) {
        case .home:
            switch mode {
            case .forumTab:
                path = []
            case .readerOverlay, .contentBrowser:
                push(.home)
            }
        case let .tag(target, page):
            push(.tag(target: target, page: page))
        case let .board(fid, title, page):
            push(.board(fid: fid, title: title, page: page))
        case let .thread(threadURL):
            openThread(
                threadURL,
                title: title,
                containingFid: nil,
                intent: source == .readerOrigin || source == .readerDiscussion ? .nativeThreadReader : .contentRoute,
                isDiscussionView: source == .readerDiscussion,
                fromBrowserList: fromBrowserList
            )
        case let .userSpace(uid, name):
            push(.userSpace(uid: uid, name: name, section: .space, subPage: .profile))
        case let .messageCenter(tab):
            push(.messageCenter(tab: tab))
        case let .privateMessage(uid, name):
            push(.privateMessage(uid: uid, name: name))
        case let .blog(blogID, uid, title):
            push(.blog(blogID: blogID, uid: uid, title: title))
        case let .postEditor(url):
            push(.postEditor(url))
        case let .blogEditor(url):
            push(.blogEditor(url))
        case let .actionForm(url):
            push(.actionForm(url))
        case let .announcement(url):
            push(.announcement(url))
        case let .web(url):
            push(.web(url))
        }
    }

    func openBoard(_ board: ForumBoardSummary, fromBrowserList: Bool = false) {
        if fromBrowserList && browserUsesSplitNavigation { path = browserListPath }
        push(.board(fid: board.fid, title: board.name, page: nil))
    }

    func openSearch(fid: String?, fromBrowserList: Bool = false) {
        if fromBrowserList && browserUsesSplitNavigation { path = browserListPath }
        if path.last != .search(fid: fid) { push(.search(fid: fid)) }
    }

    func openCarouselItem(_ item: ForumHomeCarouselItem, fromBrowserList: Bool = false) {
        if item.isThreadTarget {
            openThread(item.targetURL, title: nil, containingFid: nil, fromBrowserList: fromBrowserList)
        }
    }

    @discardableResult
    func openThread(
        _ url: URL,
        title: String?,
        containingFid: String?,
        intent: YamiboThreadRouteIntent = .contentRoute,
        readerOverride: YamiboThreadReaderOverride? = nil,
        isDiscussionView: Bool = false,
        fromBrowserList: Bool = false
    ) -> Task<Void, Never>? {
        if mode == .readerOverlay {
            pushThreadLink(url: url, title: title, containingFid: containingFid, isDiscussionView: isDiscussionView)
            return nil
        }
        let sourceListPath = browserListPath
        let replacesDetail = fromBrowserList && browserUsesSplitNavigation
        cancelThreadOpen()
        let openID = UUID()
        browserOpenID = openID
        let accountGeneration = actions.accountGeneration()
        let task = Task {
            defer { if browserOpenID == openID { finishThreadOpen() } }
            do {
                let resolver = await dependencies.forum.makeThreadRouteResolver()
                try Task.checkCancellation()
                let resolution = try await resolver.resolveWithPage(
                    YamiboThreadRouteRequest(
                        threadURL: url,
                        title: title,
                        intent: intent,
                        readerOverride: readerOverride,
                        tapContext: YamiboThreadTapContext(containingFid: containingFid)
                    )
                )
                try Task.checkCancellation()
                guard accountGeneration == actions.accountGeneration() else { return }
                guard browserOpenID == openID else { return }
                guard !fromBrowserList || (browserOpenID == openID && browserListPath == sourceListPath) else { return }
                finishThreadOpen()
                if replacesDetail { path = sourceListPath }
                openYamiboThreadRouteTarget(resolution.target, preloadedPage: resolution.preloadedPage, isDiscussionView: isDiscussionView)
            } catch {
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error),
                   accountGeneration == actions.accountGeneration(),
                   browserOpenID == openID,
                   !fromBrowserList || (browserOpenID == openID && browserListPath == sourceListPath) {
                    actionErrorMessage = error.localizedDescription
                    actionErrorDetails = LoadFailureDetails(error: error)
                }
            }
        }
        threadOpenTask = task
        return task
    }

    @discardableResult
    func openThread(
        _ thread: ForumThreadSummary,
        containingFid: String?,
        readerOverride: YamiboThreadReaderOverride? = nil,
        fromBrowserList: Bool = false
    ) -> Task<Void, Never>? {
        if mode == .readerOverlay {
            pushThreadLink(
                url: thread.url,
                title: thread.title,
                containingFid: containingFid ?? thread.fid,
                authorID: thread.authorID
            )
            return nil
        }
        let sourceListPath = browserListPath
        let replacesDetail = fromBrowserList && browserUsesSplitNavigation
        cancelThreadOpen()
        let openID = UUID()
        browserOpenID = openID
        let accountGeneration = actions.accountGeneration()
        let task = Task {
            defer { if browserOpenID == openID { finishThreadOpen() } }
            do {
                let resolver = await dependencies.forum.makeThreadRouteResolver()
                try Task.checkCancellation()
                let resolution = try await resolver.resolveWithPage(
                    YamiboThreadRouteRequest(
                        threadURL: thread.url,
                        threadID: thread.tid,
                        title: thread.title,
                        authorID: thread.authorID,
                        threadFid: thread.fid,
                        readerOverride: readerOverride,
                        tapContext: YamiboThreadTapContext(containingFid: containingFid)
                    )
                )
                try Task.checkCancellation()
                guard accountGeneration == actions.accountGeneration() else { return }
                guard browserOpenID == openID else { return }
                guard !fromBrowserList || (browserOpenID == openID && browserListPath == sourceListPath) else { return }
                finishThreadOpen()
                if replacesDetail { path = sourceListPath }
                openYamiboThreadRouteTarget(resolution.target, preloadedPage: resolution.preloadedPage)
            } catch {
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error),
                   accountGeneration == actions.accountGeneration(),
                   browserOpenID == openID,
                   !fromBrowserList || (browserOpenID == openID && browserListPath == sourceListPath) {
                    actionErrorMessage = error.localizedDescription
                    actionErrorDetails = LoadFailureDetails(error: error)
                }
            }
        }
        threadOpenTask = task
        return task
    }

    /// The thread card long-press menu's one-off reading-mode handler, or
    /// `nil` where the stack cannot honor the choice: a reader-overlay stack
    /// never launches a second full reader (every thread opens as a native
    /// thread page there), so offering the menu would promise nothing.
    func threadReaderOverrideHandler(
        containingFid: String?,
        fromBrowserList: Bool = false
    ) -> ((ForumThreadSummary, YamiboThreadReaderOverride) -> Void)? {
        guard mode != .readerOverlay else { return nil }
        return { thread, readerOverride in
            self.openThread(thread, containingFid: containingFid, readerOverride: readerOverride, fromBrowserList: fromBrowserList)
        }
    }

    /// Same menu for a board's 置顶 rows. Announcement rows are filtered out by
    /// the row itself (no `threadID`, so nothing to apply a reader to); this
    /// only decides whether the stack can honor a choice at all.
    func pinnedReaderOverrideHandler(
        containingFid: String?,
        fromBrowserList: Bool = false
    ) -> ((ForumPinnedItem, YamiboThreadReaderOverride) -> Void)? {
        guard mode != .readerOverlay else { return nil }
        return { item, readerOverride in
            self.openPinnedItem(item, containingFid: containingFid, readerOverride: readerOverride, fromBrowserList: fromBrowserList)
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

    func openCreditLog() {
        push(.creditLog)
    }

    func openPinnedItem(
        _ item: ForumPinnedItem,
        containingFid: String?,
        readerOverride: YamiboThreadReaderOverride? = nil,
        fromBrowserList: Bool = false
    ) {
        if item.threadID != nil {
            openThread(
                item.url,
                title: item.title,
                containingFid: containingFid,
                readerOverride: readerOverride,
                fromBrowserList: fromBrowserList
            )
        } else {
            route(item.url, source: .external, fromBrowserList: fromBrowserList)
        }
    }

    func openPostThreadComposer(fid: String) {
        var components = URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/forum.php"
        components.queryItems = [
            .init(name: "mod", value: "post"),
            .init(name: "action", value: "newthread"),
            .init(name: "fid", value: fid),
            .init(name: "mobile", value: "2")
        ]
        if let url = components.url {
            push(.postEditor(url))
        }
    }

    /// An explicit content destination bypasses classification, not loading or permissions.
    func openContent(_ url: URL, destination: AppContentDestination) {
        guard !isOpeningContent,
              let tid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "tid" })?.value else { return }
        let revision = pathRevision
        let generation = actions.accountGeneration()
        isOpeningContent = true
        contentOpenTask = Task {
            defer {
                isOpeningContent = false
                contentOpenTask = nil
            }
            do {
                let repository = await dependencies.forum.makeForumThreadReaderRepository()
                let page = try await repository.fetchThreadPage(context: ThreadNovelLaunchContext(
                    thread: ThreadIdentity(tid: tid), title: L10n.string("forum.default_title")
                ), page: 1, authorID: nil, reverse: false)
                try Task.checkCancellation()
                guard revision == pathRevision, generation == actions.accountGeneration() else { return }
                let thread = ThreadIdentity(tid: tid, fid: page.forumID ?? page.thread.fid)
                let novelContext = NovelDetailLaunchContext(thread: thread, title: page.title, authorID: page.posts.first?.author.uid)
                let mangaContext = MangaDetailLaunchContext(
                    thread: thread, title: MangaTitleCleaner.cleanBookName(page.title),
                    focusedChapterTID: tid, directoryNameHint: MangaTitleCleaner.cleanBookName(page.title)
                )
                switch destination {
                case .normalThread:
                    let context = ThreadNovelLaunchContext(thread: thread, title: page.title)
                    push(.threadReader(context))
                    preloadedThreadPages[context] = (generation, page)
                case .novelDetail:
                    push(.novelDetail(novelContext))
                case .mangaDetail:
                    push(.mangaDetail(mangaContext))
                case .novelReader:
                    let model = NovelDetailViewModel(context: novelContext, dependencies: dependencies.destinations.novelDetail)
                    await model.load()
                    try Task.checkCancellation()
                    guard revision == pathRevision, generation == actions.accountGeneration() else { return }
                    if let error = model.errorMessage {
                        actionErrorMessage = error
                        actionErrorDetails = model.errorDetails
                    } else {
                        actions.presentNovel(model.continueLaunchContext())
                    }
                case .mangaReader:
                    let settings = await dependencies.forum.settingsStore.load()
                    let context: MangaLaunchContext
                    if settings.isSmartComicModeEnabled(forumID: thread.fid) {
                        let model = MangaDetailViewModel(context: mangaContext, dependencies: dependencies.destinations.mangaDetail)
                        await model.load()
                        try Task.checkCancellation()
                        guard revision == pathRevision, generation == actions.accountGeneration() else { return }
                        guard let launch = model.continueLaunchContext() else {
                            actionErrorMessage = model.errorMessage ?? L10n.string("common.operation_failed")
                            actionErrorDetails = model.errorDetails
                            return
                        }
                        context = launch
                    } else {
                        let progress = try await dependencies.forum.readingProgressStore.load(for: .mangaThread(threadID: tid))?.manga
                        context = MangaLaunchContext(
                            originalThreadID: tid, chapterTID: tid, displayTitle: page.title,
                            source: progress == nil ? .forum : .resume,
                            chapterView: progress?.chapterView ?? 1, initialPage: progress?.mangaPageIndex ?? 0,
                            isSmartModeEnabled: false, forumID: thread.fid
                        )
                    }
                    try Task.checkCancellation()
                    guard revision == pathRevision, generation == actions.accountGeneration() else { return }
                    actions.requestManga(context)
                }
            } catch {
                guard !LoadDiagnosticError.isCancellation(error), revision == pathRevision,
                      generation == actions.accountGeneration() else { return }
                actionErrorMessage = error.localizedDescription
                actionErrorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    func cancelContentOpen() {
        contentOpenTask?.cancel()
        cancelThreadOpen()
    }

    private func cancelThreadOpen() {
        threadOpenTask?.cancel()
        finishThreadOpen()
    }

    private func finishThreadOpen() {
        threadOpenTask = nil
        browserOpenID = nil
    }

    private func openYamiboThreadRouteTarget(_ target: YamiboThreadRouteTarget, preloadedPage: ForumThreadPage? = nil, isDiscussionView: Bool = false) {
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
            // `MangaDetailView`, using the same full-screen presentation
            // path as favorites/likes/the chapter picker
            // (`appModel.presentMangaReader`) rather than a NavigationStack
            // destination. No directory concept applies here — this thread
            // is treated exactly like a normal thread (total principle,
            // decision #2), just rendered with the manga reader — so the
            // title is used as-is (no `cleanBookName` cleanup) and page 0 is
            // the only sensible start (no resume, matching
            // `MangaDetailViewModel.launchContext(for chapter:)`'s
            // existing convention of never passing `initialPage`).
            let context = MangaLaunchContext(
                originalThreadID: payload.thread.tid,
                chapterTID: payload.thread.tid,
                displayTitle: payload.title,
                source: .forum,
                isSmartModeEnabled: false,
                forumID: payload.thread.fid
            )
            actions.requestManga(context)
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
            if let preloadedPage {
                preloadedThreadPages[context] = (actions.accountGeneration(), preloadedPage)
            }
        case let .webFallback(url):
            push(.webFallback(url))
        }
    }
}
