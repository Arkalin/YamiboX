import Foundation
import Observation
import YamiboXCore

protocol ForumThreadPageLoading: Sendable {
    func cachedThreadPage(
        context: ThreadNovelLaunchContext,
        page: Int,
        authorID: String?,
        reverse: Bool
    ) async -> ForumThreadPage?
    func fetchThreadPage(
        context: ThreadNovelLaunchContext,
        page: Int,
        authorID: String?,
        reverse: Bool
    ) async throws -> ForumThreadPage
    func fetchRatingResults(threadID: String, postID: String) async throws -> ForumThreadRatingResultsPage
    func fetchRateOptions(threadID: String, postID: String) async throws -> ForumThreadRateOptionsPage
    func fetchPollVoters(threadID: String, optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage
    func votePoll(forumID: String, threadID: String, optionIDs: [String], formHash: String) async throws -> String
    func ratePost(
        threadID: String,
        postID: String,
        score: Int,
        reason: String,
        formHash: String,
        noticeAuthor: Bool
    ) async throws -> String
    func commentPost(threadID: String, postID: String, message: String, formHash: String, page: Int) async throws -> String
}

extension ForumThreadReaderRepository: ForumThreadPageLoading {}

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
    var isFavorited = false
    private var readerMenuSettings = BoardReaderSettings(entries: [:])
    var favoriteErrorMessage: String? {
        didSet { favoriteErrorDetails = nil }
    }
    var favoriteErrorDetails: LoadFailureDetails?
    var favoriteAddPromptPresented = false
    var favoriteRemovePrompt: FavoriteRemovePrompt?
    var favoriteLocationPickerContext: FavoriteLocationPickerContext?
    @ObservationIgnored private var pendingFavoriteLocations: [FavoriteLocation]?
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

    let context: ThreadNovelLaunchContext

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumThreadPageLoading
    @ObservationIgnored private let localFavoriteLibraryStoreProvider: @Sendable () async -> FavoriteLibraryStore?
    @ObservationIgnored private let readingProgressStoreProvider: @Sendable () async -> ReadingProgressStore
    @ObservationIgnored private let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    @ObservationIgnored private let favoriteRepositoryProvider: @Sendable () async -> (any ForumThreadFavoriteRemoteOperating)?
    @ObservationIgnored private let contentCoverStoreProvider: @Sendable () async -> ContentCoverStore?
    @ObservationIgnored private let mangaDirectoryStoreProvider: @Sendable () async -> (any MangaDirectoryPersisting)?
    @ObservationIgnored private let settingsStoreProvider: @Sendable () async -> SettingsStore?
    @ObservationIgnored private let progressSync: ProgressSyncModule
    @ObservationIgnored private var latestVisibleAnchorPostID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledSubmissionID: UUID?
    @ObservationIgnored private let resolveReplyTarget: @Sendable (URL) async -> YamiboThreadRoutePayload?
    /// The thread starter's uid, needed to scope 只看楼主. Captured from the
    /// first post of an unfiltered forward-ordered page 1 — the only place it
    /// shows up — and resolved on demand when this session never loaded that
    /// page (a resumed session opens deep into the thread).
    @ObservationIgnored private var threadAuthorID: String?

    init(context: ThreadNovelLaunchContext, dependencies: ForumDependencies) {
        self.context = context
        threadAuthorID = context.authorID
        resolveReplyTarget = { url in
            let resolver = await dependencies.makeThreadRouteResolver()
            if case let .thread(payload) = try? await resolver.resolve(
                YamiboThreadRouteRequest(threadURL: url, intent: .nativeThreadReader)
            ) { return payload }
            return nil
        }
        repositoryProvider = {
            await dependencies.makeForumThreadReaderRepository()
        }
        localFavoriteLibraryStoreProvider = {
            dependencies.localFavoriteLibraryStore
        }
        readingProgressStoreProvider = {
            dependencies.readingProgressStore
        }
        browsingHistoryWorkflow = dependencies.browsingHistoryWorkflow
        favoriteRepositoryProvider = {
            await dependencies.makeFavoriteRepository()
        }
        contentCoverStoreProvider = {
            dependencies.contentCoverStore
        }
        mangaDirectoryStoreProvider = {
            dependencies.mangaDirectoryStore
        }
        settingsStoreProvider = {
            dependencies.settingsStore
        }
        progressSync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                readingProgressStore: dependencies.readingProgressStore,
                browsingHistoryWorkflow: dependencies.browsingHistoryWorkflow,
                settingsStore: dependencies.settingsStore
            )
        )
    }

    init(
        context: ThreadNovelLaunchContext,
        repository: any ForumThreadPageLoading,
        localFavoriteLibraryStore: FavoriteLibraryStore? = nil,
        readingProgressStore: ReadingProgressStore,
        browsingHistoryWorkflow: BrowsingHistoryWorkflow,
        favoriteRepository: (any ForumThreadFavoriteRemoteOperating)? = nil,
        contentCoverStore: ContentCoverStore? = nil,
        mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil,
        settingsStore: SettingsStore? = nil,
        resolveReplyTarget: @escaping @Sendable (URL) async -> YamiboThreadRoutePayload? = { _ in nil }
    ) {
        self.context = context
        self.resolveReplyTarget = resolveReplyTarget
        threadAuthorID = context.authorID
        repositoryProvider = {
            repository
        }
        localFavoriteLibraryStoreProvider = {
            localFavoriteLibraryStore
        }
        readingProgressStoreProvider = {
            readingProgressStore
        }
        self.browsingHistoryWorkflow = browsingHistoryWorkflow
        favoriteRepositoryProvider = {
            favoriteRepository
        }
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
        flushReadingProgress()
        becameReaderCompanion = true
        isSuspendedForModeSwitch = true
        restoredAnchorPostID = latestVisibleAnchorPostID ?? targetPostID ?? restoredAnchorPostID
        hasConsumedLaunchTarget = true
        generation += 1
        isLoading = false
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
        guard page == nil else { return }
        await refreshFavoriteState()
        var initialPage = context.initialPage
        // Resume is opt-in. Explicit post/page links still take precedence.
        if context.targetPostID == nil, context.initialPage <= 1,
           await settingsStoreProvider()?.load().readingProgress.savesNormalThreadProgress == true,
           let savedProgress = await readingProgressStoreProvider().load(for: .normalThread(threadID: context.thread.tid))?.thread {
            initialPage = max(1, savedProgress.lastPage)
            restoredAnchorPostID = savedProgress.anchorPostID
        }
        if await loadPage(initialPage, preferCache: change == nil), !Task.isCancelled {
            handledSubmissionID = change?.id
        }
    }

    private func refresh(after change: ForumSubmissionChange) async {
        // Resolving a findpost URL can suspend. A page turn or mode switch
        // during that lookup must win over the submission's older intent.
        generation += 1
        let requestGeneration = generation
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        let anchor = latestVisibleAnchorPostID ?? restoredAnchorPostID
        var destination: YamiboThreadRoutePayload?
        if case let .post(.reply, _, _, replyURL) = change.kind,
           let replyURL, !isFilteredView {
            let resolved = await resolveReplyTarget(replyURL)
            if resolved?.thread.tid == context.thread.tid, resolved?.targetPostID != nil {
                destination = resolved
            }
        }
        guard generation == requestGeneration, !Task.isCancelled else { return }
        let loaded = await loadPage(
            destination?.initialPage ?? currentPage,
            preferCache: false,
            preservesCurrentContentOnFailure: true,
            locatingReply: destination?.targetPostID.map { ($0, currentPage) }
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
        guard isEnabled != isAuthorOnly else { return }
        if isEnabled, threadAuthorID == nil {
            generation += 1
            let requestGeneration = generation
            isLoading = true
            let resolved: String?
            do {
                resolved = try await resolveThreadAuthorID()
            } catch {
                guard requestGeneration == generation else { return }
                isLoading = false
                transientFeedback = .failure(error, message: L10n.string("forum.thread.author_only_unavailable"))
                return
            }
            guard requestGeneration == generation else { return }
            isLoading = false
            guard let resolved else {
                guard !Task.isCancelled else { return }
                transientFeedback = .failure(L10n.string("forum.thread.author_only_unavailable"))
                return
            }
            threadAuthorID = resolved
        }
        isAuthorOnly = isEnabled
        await reloadAfterViewModeChange()
    }

    /// Turns 倒序浏览 on or off, restarting at page 1 for the same reason
    /// `setAuthorOnly` does — reversed page 1 holds the newest replies.
    func setReverseOrder(_ isEnabled: Bool) async {
        guard isEnabled != isReverseOrder else { return }
        isReverseOrder = isEnabled
        await reloadAfterViewModeChange()
    }

    func clearFavoriteError() {
        favoriteErrorMessage = nil
    }

    func clearTransientMessage() {
        transientMessage = nil
    }

    /// Routes the star button through the remembered add/remove sync choices:
    /// either performs the action silently or raises the matching prompt.
    func toggleFavorite() async {
        let settings = await favoriteSettings()
        if let favoriteItem = await localFavoriteItem(forThreadID: context.thread.tid) {
            let favorite = favoriteItem.favorite(type: .other)
            let canRemoveRemote = await favoriteRepositoryProvider() != nil
                && favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performFavoriteRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }

        let canSyncRemote = await favoriteRepositoryProvider() != nil
        switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: canSyncRemote) {
        case .prompt:
            favoriteAddPromptPresented = true
        case let .silent(syncToRemote):
            await performFavoriteAdd(syncToRemote: syncToRemote)
        }
    }

    func confirmFavoriteAdd(syncToRemote: Bool, remember: Bool) async {
        favoriteAddPromptPresented = false
        if remember {
            await rememberAddSyncChoice(syncToRemote)
        }
        await performFavoriteAdd(syncToRemote: syncToRemote)
    }

    func confirmFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool, remember: Bool) async {
        favoriteRemovePrompt = nil
        if remember {
            await rememberRemoveRemoteChoice(removeRemote)
        }
        await performFavoriteRemoval(favorite, removeRemote: removeRemote)
    }

    /// Star button long-press: opens the location picker pre-filled with
    /// this item's current locations (empty if not yet favorited).
    func presentFavoriteLocationPicker() async {
        guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else { return }
        let document = (try? await localFavoriteLibraryStore.load()) ?? FavoriteLibraryDocument()
        let currentLocations = await localFavoriteItem(forThreadID: context.thread.tid)?.locations ?? []
        favoriteLocationPickerContext = FavoriteLocationPickerContext(
            document: document,
            initialSelection: Set(currentLocations),
            isFavorited: isFavorited,
            localFavoriteLibraryStore: localFavoriteLibraryStore
        )
    }

    /// Routes the picker's confirmed selection: not-yet-favorited creates
    /// with those locations (still subject to the add-sync prompt); already
    /// favorited with a non-empty selection re-pins locally; already
    /// favorited with everything cleared is treated as unfavoriting, through
    /// the normal remove-sync decision — mirroring Android.
    func confirmFavoriteLocationSelection(_ locations: Set<FavoriteLocation>) async {
        favoriteLocationPickerContext = nil
        guard let favoriteItem = await localFavoriteItem(forThreadID: context.thread.tid) else {
            guard !locations.isEmpty else { return }
            pendingFavoriteLocations = Array(locations)
            let settings = await favoriteSettings()
            let canSyncRemote = await favoriteRepositoryProvider() != nil
            switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: canSyncRemote) {
            case .prompt:
                favoriteAddPromptPresented = true
            case let .silent(syncToRemote):
                await performFavoriteAdd(syncToRemote: syncToRemote)
            }
            return
        }
        let favorite = favoriteItem.favorite(type: .other)
        guard !locations.isEmpty else {
            let settings = await favoriteSettings()
            let canRemoveRemote = await favoriteRepositoryProvider() != nil
                && favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performFavoriteRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }
        await performFavoriteRelocate(Array(locations))
    }

    private func performFavoriteAdd(syncToRemote: Bool) async {
        let locations = pendingFavoriteLocations
        pendingFavoriteLocations = nil
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            let result = try await FavoriteCommands.addFavorite(
                threadID: context.thread.tid,
                title: favoriteTitle,
                type: .other,
                authorID: nil,
                forumID: resolvedForumID,
                forumName: page?.forumName,
                contentUpdatedAt: Self.contentUpdatedAt(from: page),
                locations: locations,
                formHash: page?.formHash,
                syncToRemote: syncToRemote,
                boardReaderSettings: await boardReaderSettings(),
                localFavoriteLibraryStore: localFavoriteLibraryStore,
                remoteRepository: await favoriteRepositoryProvider()
            )
            if let coverCandidate = ThreadCoverResolver.findThreadCoverCandidate(in: page),
               let coverStore = await contentCoverStoreProvider() {
                do {
                    _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: context.thread.tid))
                } catch {
                    YamiboLog.library.error("Failed to set automatic cover for thread \(self.context.thread.tid) during favorite add: \(error)")
                }
            }
            isFavorited = true
            if let directoryTitle = await autoAttributionDirectoryTitle(localFavoriteLibraryStore: localFavoriteLibraryStore) {
                transientFeedback = TransientFeedback(
                    message: L10n.string("favorites.quick.auto_attributed", result.remote.addFeedbackMessage, directoryTitle),
                    details: result.failureDetails
                )
            } else {
                transientFeedback = result.feedback
            }
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                favoriteErrorMessage = error.localizedDescription
                favoriteErrorDetails = LoadFailureDetails(error: error)
            }
            await refreshFavoriteState()
        }
    }

    private func performFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool) async {
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            try await FavoriteCommands.removeFavorite(
                favorite,
                removeRemote: removeRemote,
                boardReaderSettings: await boardReaderSettings(),
                localFavoriteLibraryStore: localFavoriteLibraryStore,
                remoteRepository: await favoriteRepositoryProvider()
            )
            isFavorited = false
            transientMessage = removeRemote
                ? L10n.string("favorites.quick.removed_with_remote")
                : L10n.string("favorites.quick.removed")
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                favoriteErrorMessage = error.localizedDescription
                favoriteErrorDetails = LoadFailureDetails(error: error)
            }
            await refreshFavoriteState()
        }
    }

    private func performFavoriteRelocate(_ locations: [FavoriteLocation]) async {
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            try await FavoriteCommands.relocateFavorite(
                threadID: context.thread.tid,
                locations: locations,
                localFavoriteLibraryStore: localFavoriteLibraryStore
            )
            transientMessage = L10n.string("favorites.quick.relocated")
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                favoriteErrorMessage = error.localizedDescription
                favoriteErrorDetails = LoadFailureDetails(error: error)
            }
        }
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

    private func favoriteSettings() async -> FavoriteLibrarySettings {
        guard let settingsStore = await settingsStoreProvider() else {
            return FavoriteLibrarySettings()
        }
        return await settingsStore.load().favorites
    }

    private func boardReaderSettings() async -> BoardReaderSettings {
        guard let settingsStore = await settingsStoreProvider() else {
            return BoardReaderSettings()
        }
        return await settingsStore.load().boardReader
    }

    private func rememberAddSyncChoice(_ syncToRemote: Bool) async {
        guard let settingsStore = await settingsStoreProvider() else { return }
        await FavoriteCommands.rememberAddSyncChoice(syncToRemote, settingsStore: settingsStore)
    }

    private func rememberRemoveRemoteChoice(_ removeRemote: Bool) async {
        guard let settingsStore = await settingsStoreProvider() else { return }
        await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
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
        locatingReply: (postID: String, fallbackPage: Int)? = nil
    ) async -> Bool {
        generation += 1
        let requestGeneration = generation
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
            var loaded = if preferCache, let cached = await repository.cachedThreadPage(
                context: context,
                page: page,
                authorID: authorID,
                reverse: reverse
            ) {
                cached
            } else {
                try await repository.fetchThreadPage(
                    context: context,
                    page: page,
                    authorID: authorID,
                    reverse: reverse
                )
            }
            guard requestGeneration == generation else { return false }
            var loadedPageNumber = page
            if let locatingReply, !loaded.posts.contains(where: { $0.postID == locatingReply.postID }),
               page != locatingReply.fallbackPage {
                // findpost resolution is best-effort. If its fallback page
                // does not contain the reply, refresh the original page
                // instead of moving the reader to an unrelated position.
                loaded = try await repository.fetchThreadPage(
                    context: context, page: locatingReply.fallbackPage, authorID: authorID, reverse: reverse
                )
                guard requestGeneration == generation else { return false }
                loadedPageNumber = locatingReply.fallbackPage
            }
            self.page = loaded
            currentPage = loaded.pageNavigation?.currentPage ?? loadedPageNumber
            captureThreadAuthorIDIfNeeded(from: loaded)
            handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
            return true
        } catch {
            guard requestGeneration == generation else { return false }
            let repository = await repositoryProvider()
            if usesCachedFallbackOnFailure,
               let cached = await repository.cachedThreadPage(
                   context: context,
                   page: page,
                   authorID: authorID,
                   reverse: reverse
               ) {
                guard requestGeneration == generation else { return false }
                self.page = cached
                currentPage = cached.pageNavigation?.currentPage ?? page
                errorMessage = nil
                transientFeedback = .failure(error, message: L10n.string("forum.thread.refresh_failed", error.localizedDescription))
                captureThreadAuthorIDIfNeeded(from: cached)
                handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
                return false
            }

            guard requestGeneration == generation else { return false }
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

    private func refreshFavoriteState() async {
        isFavorited = await localFavoriteItem(forThreadID: context.thread.tid) != nil
    }

    private func localFavoriteItem(forThreadID threadID: String) async -> FavoriteItem? {
        guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else { return nil }
        let target = FavoriteItemTarget.normalThread(threadID: threadID)
        return (try? await localFavoriteLibraryStore.load())?.items.first { item in
            item.target.id == target.id || item.target.threadID == target.threadID
        }
    }
}
