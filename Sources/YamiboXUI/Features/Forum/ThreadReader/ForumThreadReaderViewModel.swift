import Foundation
import Observation
import YamiboXCore


@MainActor
@Observable
final class ForumThreadReaderViewModel {
    var page: ForumThreadPage?
    var currentPage = 1
    var isLoading = false
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    private(set) var errorDetails: LoadFailureDetails?
    var transientFeedback: TransientFeedback?
    var transientMessage: String? {
        get { transientFeedback?.message }
        set { transientFeedback = newValue.map { TransientFeedback(message: $0) } }
    }
    let favoriteActions: FavoriteActionController
    var isFavorited: Bool { favoriteActions.isFavorited }
    private var readerMenuSettings = BoardReaderSettings(entries: [:])
    /// Floor anchor loaded from saved reading progress, pending its one
    /// restore scroll (browsing-history decision #8). The body view scrolls
    /// to it once the page renders, then calls `consumeRestoredAnchor()`.
    /// While non-nil, incoming visible-anchor updates are ignored so the
    /// initial top-of-page render can't overwrite the saved anchor before
    /// the restore scroll happens.
    var restoredAnchorPostID: String?
    /// 只看楼主 — pages are requested scoped to `threadAuthorID`.
    var isAuthorOnly = false
    /// 倒序浏览 — pages are requested newest-first (Discuz `ordertype=1`).
    var isReverseOrder = false
    var persistsReadingActivity = true
    var recordsReaderSessionHistory = false
    @ObservationIgnored private var hasRecordedBrowsingHistoryVisit = false
    @ObservationIgnored private var isSuspendedForModeSwitch = false
    @ObservationIgnored private var hasConsumedLaunchTarget = false
    private(set) var becameReaderCompanion = false

    private(set) var context: ThreadNovelLaunchContext

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumThreadPageLoading
    @ObservationIgnored private let localFavoriteLibraryStoreProvider: @Sendable () async -> FavoriteLibraryStore?
    @ObservationIgnored private let readingProgressStoreProvider: @Sendable () async -> ReadingProgressStore
    @ObservationIgnored private let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    @ObservationIgnored private let contentCoverStoreProvider: @Sendable () async -> ContentCoverStore?
    @ObservationIgnored private let mangaDirectoryStoreProvider: @Sendable () async -> (any MangaDirectoryPersisting)?
    @ObservationIgnored private let settingsStoreProvider: @Sendable () async -> SettingsStore?
    @ObservationIgnored private let progressSync: ProgressSyncModule
    @ObservationIgnored private var latestVisibleAnchorPostID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pageLoadTask: Task<Bool, Never>?
    @ObservationIgnored private var pageLoadKey: PageLoadKey?
    @ObservationIgnored private var needsViewModeReload = false
    private struct PageLoadKey: Equatable {
        var page: Int
        var authorID: String?
        var reverse: Bool
        var preferCache: Bool
        var preservesContent: Bool
        var usesFallback: Bool
        var replyID: String?
        var replyFallbackPage: Int?
    }
    @ObservationIgnored private var handledSubmissionID: UUID?
    @ObservationIgnored private var initialPreloadedPage: ForumThreadPage?
    @ObservationIgnored private let resolveReplyTarget: @Sendable (URL) async -> YamiboThreadRouteResolution?
    /// The thread starter's uid, needed to scope 只看楼主. Captured from the
    /// first post of an unfiltered forward-ordered page 1 — the only place it
    /// shows up — and resolved on demand when this session never loaded that
    /// page (a resumed session opens deep into the thread).
    @ObservationIgnored private var threadAuthorID: String?
    @ObservationIgnored private var enqueueAttachmentRequest: (@Sendable (ForumAttachmentDownloadRequest) async throws -> ForumAttachmentEnqueueResult)?

    convenience init(context: ThreadNovelLaunchContext, dependencies: ForumDependencies, preloadedPage: ForumThreadPage? = nil) {
        self.init(
            context: context,
            repositoryProvider: dependencies.makeForumThreadReaderRepository,
            localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            browsingHistoryWorkflow: dependencies.browsingHistoryWorkflow,
            makeFavoriteRepository: dependencies.makeFavoriteRepository,
            contentCoverStore: dependencies.contentCoverStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore,
            resolveReplyTarget: { [makeResolver = dependencies.makeThreadRouteResolver] url in
                let resolver = await makeResolver()
                return try? await resolver.resolveWithPage(
                    YamiboThreadRouteRequest(threadURL: url, intent: .nativeThreadReader)
                )
            }
        )
        enqueueAttachmentRequest = { request in
            let executor = await dependencies.makeDownloadQueueExecutor()
            let result = try await dependencies.attachmentDownloadStore.enqueueAttachmentDownload(request)
            if case .alreadyDownloaded = result { return result }
            try await executor.continueQueue()
            return result
        }
        seedInitialPage(preloadedPage)
    }

    func enqueueAttachment(_ attachment: ForumThreadAttachmentBlock) async {
        guard let enqueueAttachmentRequest else { return }
        let request = ForumAttachmentDownloadRequest(
            threadID: context.thread.tid,
            threadTitle: navigationTitle,
            attachment: attachment,
            refererURL: YamiboRoute.threadByID(tid: context.thread.tid, page: currentPage, authorID: nil, reverse: false).url
        )
        do {
            let result = try await enqueueAttachmentRequest(request)
            switch result {
            case .enqueued: transientMessage = L10n.string("downloads.attachment.enqueued")
            case .alreadyQueued: transientMessage = L10n.string("downloads.attachment.queued")
            case .alreadyDownloaded: transientMessage = L10n.string("settings.download.state.downloaded")
            }
        } catch {
            guard !LoadDiagnosticError.isCancellation(error) else { return }
            transientMessage = error.localizedDescription
        }
    }

    convenience init(
        context: ThreadNovelLaunchContext,
        repository: any ForumThreadPageLoading,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        favoriteRepository: any ForumThreadFavoriteRemoteOperating,
        contentCoverStore: ContentCoverStore? = nil,
        mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil,
        settingsStore: SettingsStore,
        resolveReplyTarget: @escaping @Sendable (URL) async -> YamiboThreadRouteResolution? = { _ in nil }
    ) {
        self.init(
            context: context,
            repositoryProvider: { repository },
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            browsingHistoryWorkflow: browsingHistoryWorkflow,
            makeFavoriteRepository: { favoriteRepository },
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore,
            settingsStore: settingsStore,
            resolveReplyTarget: resolveReplyTarget
        )
    }

    private init(
        context: ThreadNovelLaunchContext,
        repositoryProvider: @escaping @Sendable () async -> any ForumThreadPageLoading,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating,
        contentCoverStore: ContentCoverStore?,
        mangaDirectoryStore: (any MangaDirectoryPersisting)?,
        settingsStore: SettingsStore,
        resolveReplyTarget: @escaping @Sendable (URL) async -> YamiboThreadRouteResolution?
    ) {
        self.context = context
        favoriteActions = FavoriteActionController(
            threadID: context.thread.tid, type: .other, defaultTitle: context.title,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore, makeFavoriteRepository: makeFavoriteRepository,
            scope: .thread(context.thread.tid)
        )
        self.resolveReplyTarget = resolveReplyTarget
        threadAuthorID = context.authorID
        self.repositoryProvider = repositoryProvider
        localFavoriteLibraryStoreProvider = {
            localFavoriteLibraryStore
        }
        readingProgressStoreProvider = {
            readingProgressStore
        }
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        contentCoverStoreProvider = {
            contentCoverStore
        }
        mangaDirectoryStoreProvider = {
            mangaDirectoryStore
        }
        settingsStoreProvider = {
            settingsStore
        }
        progressSync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                readingProgressStore: readingProgressStore,
                browsingHistoryWorkflow: browsingHistoryWorkflow,
                settingsStore: settingsStore
            )
        )
        configureFavoriteActions()
    }

    var navigationTitle: String {
        page?.title ?? context.title
    }

    /// Cover menu entries for images opened from this thread: thread cover
    /// always, manga cover when the thread is a chapter of a local directory
    /// and its board currently has Smart Comic Mode on (design decision
    /// #16 — mode off hides this entry outright, even if a `MangaDirectory`
    /// technically still exists for this tid).
    var imageBrowserCoverActionsProvider: ImageBrowserCoverActionsProvider {
        let forumID = resolvedForumID
        return ImageBrowserThreadCoverActions.provider(
            tid: context.thread.tid,
            contentCoverStore: contentCoverStoreProvider,
            mangaDirectoryStore: mangaDirectoryStoreProvider,
            isSmartComicModeEnabled: { [settingsStoreProvider] in
                // Strict rule, no special cases: without a settings store
                // there is no configured smart-enabled manga board, so the
                // manga-cover entry stays hidden.
                guard let settingsStore = await settingsStoreProvider() else { return false }
                return await settingsStore.load().isSmartComicModeEnabled(forumID: forumID)
            }
        )
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var targetPostID: String? {
        hasConsumedLaunchTarget ? nil : context.targetPostID
    }

    var readerSwitchThread: ThreadIdentity {
        ThreadIdentity(tid: context.thread.tid, fid: resolvedForumID)
    }

    var recommendedReaderKind: YamiboThreadKind {
        readerMenuSettings.threadKind(forumID: resolvedForumID)
    }

    func observeBoardReaderSettings() async {
        guard let settingsStore = await settingsStoreProvider() else {
            readerMenuSettings = BoardReaderSettings()
            return
        }
        let changes = settingsStore.changes()
        readerMenuSettings = await settingsStore.load().boardReader
        for await _ in changes {
            guard !Task.isCancelled else { return }
            readerMenuSettings = await settingsStore.load().boardReader
        }
    }

    var readerSwitchAuthorID: String? { threadAuthorID ?? context.authorID }

    func suspendForModeSwitch() {
        cancelPageLoad()
        flushReadingProgress()
        becameReaderCompanion = true
        isSuspendedForModeSwitch = true
        restoredAnchorPostID = latestVisibleAnchorPostID ?? targetPostID ?? restoredAnchorPostID
        hasConsumedLaunchTarget = true
        generation += 1
        isLoading = false
    }

    /// A retained model must accept the newly requested chapter anchor, not
    /// silently resume its previous floor or author/reverse filter.
    func prepareForOriginalPost(context: ThreadNovelLaunchContext, preloadedPage: ForumThreadPage?) {
        guard context.thread.tid == self.context.thread.tid else { return }
        cancelPageLoad()
        generation += 1
        initialPreloadedPage = nil
        self.context = context
        isSuspendedForModeSwitch = false
        hasConsumedLaunchTarget = false
        isAuthorOnly = false
        isReverseOrder = false
        needsViewModeReload = false
        latestVisibleAnchorPostID = nil
        restoredAnchorPostID = nil
        errorMessage = nil
        isLoading = false
        page = nil
        currentPage = context.initialPage
        if let preloadedPage, preloadedPage.thread.tid == context.thread.tid,
           (preloadedPage.pageNavigation?.currentPage ?? context.initialPage) == context.initialPage {
            page = preloadedPage
            captureThreadAuthorIDIfNeeded(from: preloadedPage)
            handlePageLoadSuccess(previousLoadedPage: nil)
        }
    }

    func seedInitialPage(_ page: ForumThreadPage?) {
        guard self.page == nil else { return }
        initialPreloadedPage = page
    }

    func load(submissionChange: ForumSubmissionChange? = nil) async {
        isSuspendedForModeSwitch = false
        let change = submissionChange.flatMap { change -> ForumSubmissionChange? in
            switch change.kind {
            case let .post(_, threadID, _, _) where threadID == context.thread.tid:
                return change
            case let .postInteraction(threadID) where threadID == context.thread.tid:
                return change
            default:
                return nil
            }
        }
        if let change, change.id != handledSubmissionID, page != nil {
            await refresh(after: change)
            return
        }
        // Cancellation retains the old page. A filter toggle may still need
        // matching content, so reentry must resume that unfinished intent.
        if needsViewModeReload {
            await loadPage(1)
            return
        }
        guard page == nil else { return }
        var initialPage = context.initialPage
        // Resume is opt-in. Explicit post/page links still take precedence.
        do {
            if context.targetPostID == nil, context.initialPage <= 1,
               await settingsStoreProvider()?.load().readingProgress.savesNormalThreadProgress == true,
               let savedProgress = try await readingProgressStoreProvider().load(for: .normalThread(threadID: context.thread.tid))?.thread {
                initialPage = max(1, savedProgress.lastPage)
                restoredAnchorPostID = savedProgress.anchorPostID
            }
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return
        }
        let seed = change == nil ? initialPreloadedPage : nil
        initialPreloadedPage = nil
        if await loadPage(initialPage, preferCache: change == nil, preloadedPage: seed), !Task.isCancelled {
            handledSubmissionID = change?.id
        }
    }

    private func refresh(after change: ForumSubmissionChange) async {
        // Resolving a findpost URL can suspend. A page turn or mode switch
        // during that lookup must win over the submission's older intent.
        cancelPageLoad()
        generation += 1
        let requestGeneration = generation
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        let anchor = latestVisibleAnchorPostID ?? restoredAnchorPostID
        var destination: YamiboThreadRoutePayload?
        var freshPage: ForumThreadPage?
        if case let .post(.reply, _, _, replyURL) = change.kind,
           let replyURL, !isFilteredView {
            let resolved = await resolveReplyTarget(replyURL)
            if case let .thread(payload) = resolved?.target,
               payload.thread.tid == context.thread.tid, payload.targetPostID != nil {
                destination = payload
                freshPage = resolved?.preloadedPage
            }
        }
        guard generation == requestGeneration, !Task.isCancelled else { return }
        let loaded = await loadPage(
            destination?.initialPage ?? currentPage,
            preferCache: false,
            preservesCurrentContentOnFailure: true,
            locatingReply: destination?.targetPostID.map { ($0, currentPage) },
            preloadedPage: freshPage
        )
        guard loaded, !Task.isCancelled else { return }
        hasConsumedLaunchTarget = true
        let replyID = destination?.targetPostID.flatMap { id in
            page?.posts.contains(where: { $0.postID == id }) == true ? id : nil
        }
        let postID = replyID ?? anchor
        if let postID, page?.posts.contains(where: { $0.postID == postID }) == true {
            restoredAnchorPostID = postID
        }
        handledSubmissionID = change.id
    }

    func refresh() async {
        await loadPage(
            currentPage,
            preferCache: false,
            preservesCurrentContentOnFailure: true,
            usesCachedFallbackOnFailure: true
        )
    }

    func retry() {
        Task {
            await refresh()
        }
    }

    func goToPage(_ page: Int) async {
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        await loadPage(nextPage)
    }

    /// Turns 只看楼主 on or off. Both directions restart at page 1: a filtered
    /// thread paginates over a different set of posts, so the page the reader
    /// is on means nothing in the other mode.
    ///
    /// Enabling needs the thread starter's uid; when this session has never
    /// seen page 1 it is resolved first, and the toggle stays off if even that
    /// fails rather than silently loading the unfiltered thread.
    func setAuthorOnly(_ isEnabled: Bool) async {
        guard !Task.isCancelled, isEnabled != isAuthorOnly else { return }
        if isEnabled, threadAuthorID == nil {
            cancelPageLoad()
            generation += 1
            let requestGeneration = generation
            isLoading = true
            defer { if requestGeneration == generation { isLoading = false } }
            let resolved: String?
            do {
                resolved = try await resolveThreadAuthorID()
            } catch {
                guard requestGeneration == generation, !Task.isCancelled,
                      !LoadDiagnosticError.isCancellation(error) else { return }
                isLoading = false
                transientFeedback = .failure(error, message: L10n.string("forum.thread.author_only_unavailable"))
                return
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            isLoading = false
            guard let resolved else {
                guard !Task.isCancelled else { return }
                transientFeedback = .failure(L10n.string("forum.thread.author_only_unavailable"))
                return
            }
            threadAuthorID = resolved
        }
        needsViewModeReload = true
        isAuthorOnly = isEnabled
        await reloadAfterViewModeChange()
    }

    /// Turns 倒序浏览 on or off, restarting at page 1 for the same reason
    /// `setAuthorOnly` does — reversed page 1 holds the newest replies.
    func setReverseOrder(_ isEnabled: Bool) async {
        guard !Task.isCancelled, isEnabled != isReverseOrder else { return }
        needsViewModeReload = true
        isReverseOrder = isEnabled
        await reloadAfterViewModeChange()
    }

    func clearTransientMessage() {
        transientMessage = nil
        favoriteActions.clearTransientMessage()
    }

    private func configureFavoriteActions() {
        let defaultTitle = context.title
        favoriteActions.makeAddMetadata = { [weak self] in
            guard let self else { return .init(title: defaultTitle) }
            return .init(
                title: favoriteTitle, forumID: resolvedForumID, forumName: page?.forumName,
                contentUpdatedAt: Self.contentUpdatedAt(from: page), formHash: page?.formHash
            )
        }
        favoriteActions.didAddFavorite = { [weak self] result in
            guard let self else { return result.feedback }
            return await favoriteAddedFeedback(result)
        }
    }

    /// Keep thread-only enrichment here; decisions, mutations and operation
    /// admission are shared with every other favorite entry point.
    private func favoriteAddedFeedback(_ result: FavoriteCommands.AddResult) async -> TransientFeedback {
        if let coverCandidate = ThreadCoverResolver.findThreadCoverCandidate(in: page),
           let coverStore = await contentCoverStoreProvider() {
            do {
                _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: context.thread.tid))
            } catch {
                YamiboLog.library.error("Failed to set automatic cover for thread \(self.context.thread.tid) during favorite add: \(error)")
            }
        }
        if let libraryStore = await localFavoriteLibraryStoreProvider(),
           let directoryTitle = await autoAttributionDirectoryTitle(localFavoriteLibraryStore: libraryStore) {
            return TransientFeedback(
                message: L10n.string("favorites.quick.auto_attributed", result.remote.addFeedbackMessage, directoryTitle),
                details: result.failureDetails
            )
        }
        return result.feedback
    }

    /// Local half of decision #8's "auto-attribution" feedback (the
    /// remote-sync half is a later phase) — the star-button add path is the
    /// most common way users hit this feature, so it gets an immediate toast
    /// rather than waiting for a sync warning that may never come.
    ///
    /// Fires only when every one of these holds, checked in this order so
    /// the cheapest gate runs first:
    /// - This board's Smart Comic Mode is on, via an explicit
    ///   `settingsStore` lookup (never inferred from a proxy signal like
    ///   "a directory happened to resolve" — that exact mistake bit three
    ///   earlier smart-comic-mode phases).
    /// - A `MangaDirectory` actually resolves for this tid (a single-tid
    ///   `directory(containingTID:)` lookup is enough here — this is one
    ///   favorite, not the batch grouping the favorites page does).
    /// - At least one *other* already-favorited `.mangaThread` item (the one
    ///   just added is already persisted by the time this runs) shares that
    ///   directory's chapter tids.
    ///
    /// Returns the directory's `cleanBookName` to interpolate into the toast,
    /// or nil to leave `transientMessage` as the plain add-feedback string.
    private func autoAttributionDirectoryTitle(localFavoriteLibraryStore: FavoriteLibraryStore) async -> String? {
        guard let settingsStore = await settingsStoreProvider() else { return nil }
        let settings = await settingsStore.load()
        guard settings.isSmartComicModeEnabled(forumID: resolvedForumID) else { return nil }
        guard let mangaDirectoryStore = await mangaDirectoryStoreProvider(),
              let directory = try? await mangaDirectoryStore.directory(containingTID: context.thread.tid) else {
            return nil
        }
        let siblingTIDs = Set(directory.chapters.map(\.tid))
        guard let document = try? await localFavoriteLibraryStore.load() else { return nil }
        // A sibling favorite only actually merges on the Favorites page if ITS
        // OWN board also has Smart Comic Mode on (LocalFavoriteLibraryProjection's
        // rawGroupedFavorites checks isSmartComicModeEnabled(forumID:) per-member, not just for
        // the item just favorited) — a MangaDirectory can span threads from
        // different boards (e.g. a `.searched` strategy match isn't fid-scoped).
        // Without this check the toast could claim "merged" for a sibling that
        // the Favorites page will actually keep standalone.
        let hasOtherFavoriteInDirectory = document.items.contains { item in
            item.target.kind == .mangaThread
                && item.target.threadID != context.thread.tid
                && siblingTIDs.contains(item.target.threadID ?? "")
                && settings.isSmartComicModeEnabled(forumID: item.forumID)
        }
        guard hasOtherFavoriteInDirectory else { return nil }
        return directory.cleanBookName
    }

    func loadRatingResults(postID: String) async throws -> ForumThreadRatingResultsPage {
        let repository = await repositoryProvider()
        return try await repository.fetchRatingResults(threadID: threadID, postID: postID)
    }

    func loadRateOptions(postID: String) async throws -> ForumThreadRateOptionsPage {
        let repository = await repositoryProvider()
        return try await repository.fetchRateOptions(threadID: threadID, postID: postID)
    }

    func loadPollVoters(optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage {
        let repository = await repositoryProvider()
        return try await repository.fetchPollVoters(threadID: threadID, optionID: optionID, page: page)
    }

    func votePoll(optionIDs: [String]) async throws -> String {
        let requestGeneration = generation
        do {
            guard let forumID = normalizedForumID, let formHash = normalizedFormHash else {
                throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
            }
            let repository = await repositoryProvider()
            let message = try await repository.votePoll(
                forumID: forumID,
                threadID: threadID,
                optionIDs: optionIDs,
                formHash: formHash
            )
            await refresh()
            return message
        } catch {
            if requestGeneration == generation { transientFeedback = .failure(error) }
            throw error
        }
    }

    func ratePost(
        postID: String,
        score: Int,
        reason: String,
        noticeAuthor: Bool
    ) async throws -> String {
        guard let formHash = normalizedFormHash else {
            throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
        }
        let repository = await repositoryProvider()
        let message = try await repository.ratePost(
            threadID: threadID,
            postID: postID,
            score: score,
            reason: reason,
            formHash: formHash,
            noticeAuthor: noticeAuthor
        )
        await refresh()
        return message
    }

    func commentPost(postID: String, message: String) async throws -> String {
        guard let formHash = normalizedFormHash else {
            throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
        }
        let repository = await repositoryProvider()
        let result = try await repository.commentPost(
            threadID: threadID,
            postID: postID,
            message: message,
            formHash: formHash,
            page: currentPage
        )
        await refresh()
        return result
    }

    func imageBrowserRequest(
        imageID: String,
        url: URL,
        title: String?,
        refererURL: URL
    ) -> ForumThreadImageBrowserRequest? {
        guard let page else { return nil }
        let defaultTitle = L10n.string("forum.thread.image")
        let gallery = ForumThreadImageBrowserGallery(
            page: page,
            refererURL: refererURL,
            selectedBlockID: imageID,
            defaultTitle: defaultTitle
        )
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackItem = ImageBrowserItem(
            id: imageID,
            source: YamiboImageSource(url: url, refererPageURL: refererURL),
            title: trimmedTitle.isEmpty ? defaultTitle : trimmedTitle
        )
        return ForumThreadImageBrowserRequest(
            items: gallery.items.isEmpty ? [fallbackItem] : gallery.items,
            initialItemID: gallery.initialItemID ?? fallbackItem.id
        )
    }

    private var threadID: String {
        page?.thread.tid ?? context.thread.tid
    }

    /// Best-known forum id for this thread, falling back from the freshest
    /// loaded page down to the launch context — used wherever a forumID is
    /// needed opportunistically (favorite add, cover-action mode gating)
    /// rather than requiring the page to already be loaded.
    private var resolvedForumID: String? {
        page?.forumID ?? page?.thread.fid ?? context.thread.fid
    }

    private var normalizedForumID: String? {
        normalized(page?.forumID)
    }

    private var normalizedFormHash: String? {
        normalized(page?.formHash)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func loadPage(
        _ page: Int,
        preferCache: Bool = true,
        preservesCurrentContentOnFailure: Bool = false,
        usesCachedFallbackOnFailure: Bool = false,
        locatingReply: (postID: String, fallbackPage: Int)? = nil,
        preloadedPage: ForumThreadPage? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let key = PageLoadKey(
            page: page, authorID: activeAuthorID, reverse: isReverseOrder,
            preferCache: preferCache, preservesContent: preservesCurrentContentOnFailure,
            usesFallback: usesCachedFallbackOnFailure,
            replyID: locatingReply?.postID, replyFallbackPage: locatingReply?.fallbackPage
        )
        guard preloadedPage != nil || pageLoadKey != key || pageLoadTask?.isCancelled == true else { return false }
        pageLoadTask?.cancel()
        generation += 1
        let requestGeneration = generation
        pageLoadKey = key
        let task = Task {
            await performPageLoad(
                page, preferCache: preferCache,
                preservesCurrentContentOnFailure: preservesCurrentContentOnFailure,
                usesCachedFallbackOnFailure: usesCachedFallbackOnFailure,
                locatingReply: locatingReply, preloadedPage: preloadedPage,
                requestGeneration: requestGeneration
            )
        }
        pageLoadTask = task
        let loaded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if requestGeneration == generation {
            pageLoadTask = nil
            pageLoadKey = nil
        }
        return loaded && !Task.isCancelled
    }

    func cancelPageLoad() {
        generation += 1
        pageLoadTask?.cancel()
        pageLoadTask = nil
        pageLoadKey = nil
        isLoading = false
    }

    private func performPageLoad(
        _ page: Int,
        preferCache: Bool,
        preservesCurrentContentOnFailure: Bool,
        usesCachedFallbackOnFailure: Bool,
        locatingReply: (postID: String, fallbackPage: Int)?,
        preloadedPage: ForumThreadPage?,
        requestGeneration: Int
    ) async -> Bool {
        guard requestGeneration == generation, !Task.isCancelled else { return false }
        isLoading = true
        errorMessage = nil
        transientMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        let previousLoadedPage = self.page == nil ? nil : currentPage

        let authorID = activeAuthorID
        let reverse = isReverseOrder

        do {
            let repository = await repositoryProvider()
            guard requestGeneration == generation, !Task.isCancelled else { return false }
            var loaded: ForumThreadPage
            if let preloadedPage, !isFilteredView,
                preloadedPage.thread.tid == context.thread.tid,
                (preloadedPage.pageNavigation?.currentPage ?? 1) == page {
                loaded = preloadedPage
            } else if preferCache, let cached = await repository.cachedThreadPage(
                context: context,
                page: page,
                authorID: authorID,
                reverse: reverse
            ) {
                loaded = cached
            } else {
                guard requestGeneration == generation, !Task.isCancelled else { return false }
                loaded = try await repository.fetchThreadPage(
                    context: context,
                    page: page,
                    authorID: authorID,
                    reverse: reverse
                )
            }
            guard requestGeneration == generation, !Task.isCancelled else { return false }
            var loadedPageNumber = page
            if let locatingReply, !loaded.posts.contains(where: { $0.postID == locatingReply.postID }),
               page != locatingReply.fallbackPage {
                // findpost resolution is best-effort. If its fallback page
                // does not contain the reply, refresh the original page
                // instead of moving the reader to an unrelated position.
                loaded = try await repository.fetchThreadPage(
                    context: context, page: locatingReply.fallbackPage, authorID: authorID, reverse: reverse
                )
                guard requestGeneration == generation, !Task.isCancelled else { return false }
                loadedPageNumber = locatingReply.fallbackPage
            }
            self.page = loaded
            needsViewModeReload = false
            currentPage = loaded.pageNavigation?.currentPage ?? loadedPageNumber
            captureThreadAuthorIDIfNeeded(from: loaded)
            handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
            return true
        } catch {
            guard requestGeneration == generation, !Task.isCancelled,
                  !LoadDiagnosticError.isCancellation(error) else { return false }
            let repository = await repositoryProvider()
            guard requestGeneration == generation, !Task.isCancelled else { return false }
            if usesCachedFallbackOnFailure,
               let cached = await repository.cachedThreadPage(
                   context: context,
                   page: page,
                   authorID: authorID,
                   reverse: reverse
               ) {
                guard requestGeneration == generation, !Task.isCancelled else { return false }
                self.page = cached
                needsViewModeReload = false
                currentPage = cached.pageNavigation?.currentPage ?? page
                errorMessage = nil
                transientFeedback = .failure(error, message: L10n.string("forum.thread.refresh_failed", error.localizedDescription))
                captureThreadAuthorIDIfNeeded(from: cached)
                handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
                return false
            }

            guard requestGeneration == generation, !Task.isCancelled else { return false }
            if preservesCurrentContentOnFailure, self.page != nil {
                errorMessage = nil
                transientFeedback = .failure(error, message: L10n.string("forum.thread.refresh_failed", error.localizedDescription))
            } else {
                self.page = nil
                currentPage = page
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                    errorMessage = error.localizedDescription
                    errorDetails = LoadFailureDetails(error: error)
                }
            }
            return false
        }
    }

    // MARK: - 只看楼主 / 倒序浏览

    /// Author scope for the pages this reader requests: set only while
    /// 只看楼主 is on, since the uid stays remembered across toggles.
    private var activeAuthorID: String? {
        isAuthorOnly ? threadAuthorID : nil
    }

    /// True while the reader shows something other than the canonical
    /// forward-ordered whole thread. Page numbers and post order both differ
    /// there, so reading progress and browsing history stay frozen at the last
    /// canonical position instead of recording a position the normal view
    /// could never resume to.
    private var isFilteredView: Bool {
        isAuthorOnly || isReverseOrder
    }

    private func reloadAfterViewModeChange() async {
        // The previous mode's anchor points at a post that need not exist —
        // or need not be at the same floor — in the new one.
        latestVisibleAnchorPostID = nil
        restoredAnchorPostID = nil
        await loadPage(1)
    }

    /// The first post of an unfiltered forward-ordered page 1 is the thread
    /// starter, and it is the only page that reveals their uid.
    private func captureThreadAuthorIDIfNeeded(from loaded: ForumThreadPage) {
        guard threadAuthorID == nil, !isFilteredView, currentPage == 1 else { return }
        threadAuthorID = loaded.posts.first?.author.uid?.nilIfBlank
    }

    /// Looks up the thread starter's uid for a session that never loaded
    /// page 1 — cached copy first, then one network read. Returns nil when the
    /// page carries no uid at all (a deleted or guest first floor).
    private func resolveThreadAuthorID() async throws -> String? {
        if let threadAuthorID { return threadAuthorID }
        let repository = await repositoryProvider()
        if let cached = await repository.cachedThreadPage(context: context, page: 1, authorID: nil, reverse: false),
           let uid = cached.posts.first?.author.uid?.nilIfBlank {
            return uid
        }
        let fetched = try await repository.fetchThreadPage(context: context, page: 1, authorID: nil, reverse: false)
        return fetched.posts.first?.author.uid?.nilIfBlank
    }

    // MARK: - Reading progress + browsing history

    /// Reported by the body view whenever the topmost rendered post changes
    /// (floor-level anchor capture). Ignored while a restored anchor is
    /// still pending its scroll, so the initial top-of-page render can't
    /// clobber the saved position before the restore happens.
    func updateVisibleAnchor(postID: String?) {
        guard !isSuspendedForModeSwitch else { return }
        guard restoredAnchorPostID == nil else { return }
        guard latestVisibleAnchorPostID != postID else { return }
        latestVisibleAnchorPostID = postID
        guard postID != nil else { return }
        queueReadingProgressSave()
    }

    func consumeRestoredAnchor() {
        // Seed the live anchor from the restored one so leaving without
        // scrolling doesn't flush a nil anchor over the saved position.
        if latestVisibleAnchorPostID == nil {
            latestVisibleAnchorPostID = restoredAnchorPostID
        }
        restoredAnchorPostID = nil
    }

    /// Exit-time write-through, called from the view's `onDisappear`. Runs
    /// in a fresh unstructured Task so view teardown can't cancel the GRDB
    /// write mid-flight (the cancelled-Task write trap).
    func flushReadingProgress() {
        guard persistsReadingActivity, page != nil, !isFilteredView else { return }
        let position = currentThreadReadingPosition()
        Task {
            do {
                try await progressSync.flush(.thread(position))
            } catch {
                YamiboLog.forum.warning("Failed to flush normal-thread reading progress on exit; next visit resumes from the last debounced save: \(error)")
            }
        }
    }

    private func handlePageLoadSuccess(previousLoadedPage: Int?) {
        if previousLoadedPage != currentPage {
            // A different page renders different posts; the old anchor is
            // meaningless there. Same-page reloads (refresh) keep it — the
            // visible cards re-report momentarily anyway.
            latestVisibleAnchorPostID = nil
        }
        recordBrowsingHistoryVisit()
        queueReadingProgressSave()
    }

    private func queueReadingProgressSave() {
        guard persistsReadingActivity, page != nil, !isFilteredView else { return }
        let position = currentThreadReadingPosition()
        Task {
            await progressSync.queue(.thread(position))
        }
    }

    private func currentThreadReadingPosition() -> ThreadReadingPosition {
        ThreadReadingPosition(
            threadID: context.thread.tid,
            page: currentPage,
            pageCount: pageNavigation?.totalPages,
            anchorPostID: latestVisibleAnchorPostID ?? restoredAnchorPostID,
            recordsBrowsingHistory: shouldRecordBrowsingHistory
        )
    }

    private var shouldRecordBrowsingHistory: Bool {
        persistsReadingActivity && (!context.isDiscussionView || recordsReaderSessionHistory) && !isFilteredView
    }

    /// Main reader-session originals count as activity, unlike comment
    /// companions. Page turns cannot resurrect a deleted history row.
    private func recordBrowsingHistoryVisit() {
        guard shouldRecordBrowsingHistory, page != nil else { return }
        let history = browsingHistoryWorkflow
        let visit = BrowsingHistoryVisit(
            threadID: context.thread.tid,
            title: favoriteTitle,
            forumID: resolvedForumID,
            reader: .normal
        )
        let isFirstVisit = !hasRecordedBrowsingHistoryVisit
        hasRecordedBrowsingHistoryVisit = true
        Task {
            do {
                if isFirstVisit { try await history.recordVisit(visit) }
                else { try await history.updateActivity(visit) }
            } catch {
                YamiboLog.forum.warning("Failed to record browsing-history visit for \(visit.threadID, privacy: .public): \(error)")
            }
        }
    }

    private var favoriteTitle: String {
        let loadedTitle = page?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !loadedTitle.isEmpty {
            return loadedTitle
        }
        let contextTitle = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return contextTitle.isEmpty ? context.thread.tid : contextTitle
    }

    private static func contentUpdatedAt(from page: ForumThreadPage?) -> Date? {
        guard let firstPost = page?.posts.first else { return nil }
        return FavoriteContentUpdateDateResolver.date(
            lastEditedText: firstPost.lastEditedText,
            postedAtText: firstPost.postedAtText
        )
    }

}
