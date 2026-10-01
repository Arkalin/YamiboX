import Foundation
import Observation
import YamiboXCore

struct NovelChapterSummary: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var view: Int
    var postID: String? = nil
    var floorText: String? = nil
    var resumePoint: NovelResumePoint? = nil
    var progressText: String? = nil
    var isCurrentRead: Bool = false
}

struct NovelChapterSection: Identifiable, Hashable, Sendable {
    var page: Int
    var chapters: [NovelChapterSummary]
    var isLoaded: Bool
    var isLoading: Bool
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?

    var id: Int { page }
}

struct NovelDetailHeaderSummary: Equatable, Sendable {
    var title: String
    var threadID: String
    var authorID: String?
    var authorName: String?
    var postedAtText: String?
    var lastUpdatedText: String?
    var forumName: String?
    var totalViews: Int?
    var totalReplies: Int?
    var coverURL: URL?
    var chapterCount: Int
    var firstFloorPreviewText: String?
    var readingProgressText: String?
    var isFavorited: Bool
    var favoriteEnabled: Bool
    var favoriteStateKnown: Bool
    var favoriteLabel: String
}

@MainActor
@Observable
final class NovelDetailViewModel {
    var document: NovelReaderProjection?
    var threadPage: ForumThreadPage?
    var chapters: [NovelChapterSummary] = []
    var chapterSections: [NovelChapterSection] = []
    var expandedChapterPages: Set<Int> = [1]
    var readingProgress: ReadingProgressRecord?
    var contentCover: ContentCover?
    var isLoading = false
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    private(set) var errorDetails: LoadFailureDetails?

    /// Favorite-star state and actions (add/remove/relocate prompts, location
    /// picker, transient feedback) — shared orchestration with the manga
    /// detail page. Its change hook rebuilds the chapter directory, whose
    /// sections render differently for favorited threads.
    let favoriteActions: FavoriteActionController

    let context: NovelDetailLaunchContext

    @ObservationIgnored private let dependencies: NovelDetailDependencies
    // Detail-scoped page cache mirroring Android's pagePostsCache; reload owns invalidation.
    @ObservationIgnored private var loadedThreadPages: [Int: ForumThreadPage] = [:]
    @ObservationIgnored private var resolvedAuthorID: String?
    @ObservationIgnored private var loadingChapterPages: Set<Int> = []
    @ObservationIgnored private var chapterPageErrors: [Int: String] = [:]
    @ObservationIgnored private var chapterPageErrorDetails: [Int: LoadFailureDetails] = [:]
    @ObservationIgnored private var totalChapterPages = 1
    @ObservationIgnored private var novelReaderSettings = NovelReaderAppearanceSettings()
    @ObservationIgnored private var readingProgressUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var favoriteRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var coverRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pageChapterSummaries: [Int: [NovelChapterSummary]] = [:]
    @ObservationIgnored private var contentGeneration = 0
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var directoryNeedsRefresh = false

    init(
        context: NovelDetailLaunchContext,
        dependencies: NovelDetailDependencies
    ) {
        self.context = context
        self.dependencies = dependencies
        favoriteActions = FavoriteActionController(
            threadID: context.thread.tid,
            type: .novel,
            defaultTitle: context.title,
            localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
            settingsStore: dependencies.settingsStore,
            makeFavoriteRepository: dependencies.makeFavoriteRepository
        )
        favoriteActions.makeAddMetadata = { @MainActor [weak self] in
            guard let self else { return .init(title: context.title) }
            return .init(
                title: self.favoriteTitle,
                authorID: self.resolvedAuthorID ?? self.context.authorID,
                forumID: self.threadPage?.forumID ?? self.threadPage?.thread.fid ?? self.context.thread.fid,
                forumName: self.threadPage?.forumName ?? self.forumName,
                contentUpdatedAt: Self.contentUpdatedAt(from: self.threadPage),
                formHash: self.threadPage?.formHash
            )
        }
        favoriteActions.onFavoriteDidChange = { @MainActor [weak self] in
            self?.rebuildChapterDirectory()
        }
    }

    deinit {
        readingProgressUpdatesTask?.cancel()
        favoriteRefreshTask?.cancel()
        coverRefreshTask?.cancel()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        readingProgressUpdatesTask?.cancel()
        readingProgressUpdatesTask = nil
        guard visible else { return }
        if directoryNeedsRefresh { rebuildChapterDirectory() }
        let store = dependencies.readingProgressStore
        let threadID = context.thread.tid
        readingProgressUpdatesTask = Task { [weak self] in
            do {
                for try await progress in await store.snapshots(threadID: threadID) {
                    guard !Task.isCancelled else { return }
                    guard let self, self.readingProgress != progress else { continue }
                    self.readingProgress = progress
                    self.rebuildChapterDirectory()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.favoriteActions.transientFeedback = .failure(error)
            }
        }
    }

    var navigationTitle: String {
        displayTitle(threadPage?.title ?? context.title)
    }

    var hasReadingProgress: Bool {
        Self.hasReadingProgress(readingProgress, favorite: favoriteActions.favorite)
    }

    var headerSummary: NovelDetailHeaderSummary {
        let firstPost = threadPage?.posts.first
        let previewPost = loadedThreadPages[1]?.posts.first
        return NovelDetailHeaderSummary(
            title: displayTitle(threadPage?.title ?? context.title),
            threadID: context.thread.tid,
            authorID: resolvedAuthorID ?? firstPost?.author.uid?.nilIfBlank ?? context.authorID,
            authorName: firstPost?.author.name.nilIfBlank,
            postedAtText: firstPost?.postedAtText,
            lastUpdatedText: Self.lastUpdatedText(
                editedText: firstPost?.lastEditedText,
                postedAtText: firstPost?.postedAtText
            ),
            forumName: forumName,
            totalViews: threadPage?.totalViews,
            totalReplies: threadPage?.totalReplies,
            coverURL: resolvedHeaderCoverURL,
            chapterCount: chapters.count,
            firstFloorPreviewText: Self.firstFloorPreviewText(from: previewPost),
            readingProgressText: Self.readingProgressText(from: readingProgress, favorite: favoriteActions.favorite),
            isFavorited: favoriteActions.isFavorited,
            favoriteEnabled: favoriteActions.canAct,
            favoriteStateKnown: favoriteActions.membership != nil,
            favoriteLabel: favoriteActions.accessibilityLabel
        )
    }

    func load() async {
        guard threadPage == nil else { return }
        await reload()
    }

    private var resolvedHeaderCoverURL: URL? {
        contentCover?.resolvedURL
            ?? threadPage.flatMap(ThreadCoverResolver.findThreadCoverCandidate(in:))
    }

    func reload() async {
        await loadDetail(preferCache: true, refreshesPersistentCache: false, preservesCurrentContentOnFailure: false)
    }

    func refresh() async {
        // Protect cache replacement as well as the network request from the
        // refresh-control task's cancellation, matching manga detail refresh.
        await Task {
            await loadDetail(preferCache: false, refreshesPersistentCache: true, preservesCurrentContentOnFailure: threadPage != nil)
        }.value
    }

    private func loadDetail(
        preferCache: Bool,
        refreshesPersistentCache: Bool,
        preservesCurrentContentOnFailure: Bool
    ) async {
        guard !isLoading, !Task.isCancelled else { return }
        let previousDocument = document
        isLoading = true
        errorMessage = nil
        favoriteActions.transientMessage = nil
        coverRefreshTask?.cancel()
        contentGeneration += 1
        let generation = contentGeneration
        favoriteRefreshTask?.cancel()
        favoriteRefreshTask = Task { [weak self] in
            await self?.favoriteActions.refreshFavorite()
        }
        document = nil
        defer { isLoading = false }

        do {
            async let progress = dependencies.readingProgressStore.load(threadID: context.thread.tid)
            async let cover = loadContentCover()
            async let settings = dependencies.settingsStore.load()
            favoriteActions.errorMessage = nil
            let threadRepository = await dependencies.makeForumThreadReaderRepository()
            try Task.checkCancellation()
            let initialPages = try await loadInitialPages(repository: threadRepository, preferCache: preferCache)
            readingProgress = try await progress
            contentCover = await cover
            novelReaderSettings = await settings.novelReader
            let headerPage = initialPages.headerPage
            let contentPage = initialPages.contentPage
            let authorID = initialPages.authorID
            let contentContext = initialPages.contentContext
            try Task.checkCancellation()
            if refreshesPersistentCache {
                try await threadRepository.clearCachedThreadPages(thread: context.thread)
                try await threadRepository.storeNovelThreadPage(headerPage, context: context, pageNumber: 1)
                if contentContext != context {
                    try await threadRepository.storeNovelThreadPage(contentPage, context: contentContext, pageNumber: 1)
                }
            }
            try Task.checkCancellation()
            let projectionRepository = await dependencies.makeNovelReaderRepository()
            let projection = try? await projectionRepository.projection(
                from: contentPage,
                request: NovelPageRequest(threadID: context.thread.tid, view: 1, authorID: authorID)
            )
            let summaries = if let projection {
                await Self.summariesOffMainActor(from: contentPage, document: projection, settings: novelReaderSettings)
            } else {
                [NovelChapterSummary]()
            }
            try Task.checkCancellation()
            guard contentGeneration == generation else { return }
            resolvedAuthorID = authorID
            threadPage = headerPage
            loadedThreadPages = [1: contentPage]
            pageChapterSummaries = [1: summaries]
            document = projection
            totalChapterPages = Self.totalPages(from: contentPage, fallback: 1)
            chapterPageErrors = [:]
            chapterPageErrorDetails = [:]
            loadingChapterPages = []
            expandedChapterPages = [1]
            rebuildChapterDirectory()
            coverRefreshTask = Task { [weak self] in
                guard let self, self.contentGeneration == generation, !Task.isCancelled else { return }
                await self.refreshContentCover(from: headerPage)
            }
        } catch {
            let networkError = error as NSError
            if Task.isCancelled || error is CancellationError ||
                (networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled) {
                document = previousDocument
                return
            }
            // Retain the last known progress; a failed read is not an empty record.
            contentCover = await loadContentCover()
            if preservesCurrentContentOnFailure {
                document = nil
                errorMessage = nil
                favoriteActions.transientFeedback = .failure(error, message: L10n.string("forum.novel_detail.refresh_failed", error.localizedDescription))
            } else {
                document = nil
                threadPage = nil
                chapters = []
                chapterSections = []
                loadedThreadPages = [:]
                pageChapterSummaries = [:]
                resolvedAuthorID = nil
                chapterPageErrors = [:]
                chapterPageErrorDetails = [:]
                loadingChapterPages = []
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                    errorMessage = error.localizedDescription
                    errorDetails = LoadFailureDetails(error: error)
                }
            }
        }
    }

    private func loadInitialPages(
        repository: any NovelDetailThreadPageLoading,
        preferCache: Bool
    ) async throws -> (headerPage: ForumThreadPage, contentPage: ForumThreadPage, authorID: String, contentContext: NovelDetailLaunchContext) {
        if let authorID = context.authorID?.nilIfBlank {
            let scopedContext = authorScopedContext(authorID: authorID)
            let page = try await loadNovelThreadPage(context: scopedContext, page: 1, preferCache: preferCache, repository: repository)
            return (page, page, authorID, scopedContext)
        }

        let headerPage = try await loadNovelThreadPage(context: context, page: 1, preferCache: preferCache, repository: repository)
        let authorID = try Self.resolveAuthorID(context: context, page: headerPage)
        let contentContext = authorScopedContext(authorID: authorID)
        let contentPage = try await loadNovelThreadPage(context: contentContext, page: 1, preferCache: preferCache, repository: repository)
        return (headerPage, contentPage, authorID, contentContext)
    }

    private func loadNovelThreadPage(
        context: NovelDetailLaunchContext,
        page: Int,
        preferCache: Bool,
        repository: any NovelDetailThreadPageLoading
    ) async throws -> ForumThreadPage {
        if preferCache,
           let cached = await repository.cachedNovelThreadPage(context: context, page: page) {
            return cached
        }
        return try await repository.fetchNovelThreadPage(context: context, page: page)
    }


    func launchContext(for chapter: NovelChapterSummary?) -> NovelLaunchContext {
        NovelLaunchContext(
            threadID: context.thread.tid,
            threadTitle: context.title,
            source: .forum,
            initialView: chapter?.view ?? 1,
            authorID: chapter?.resumePoint?.authorID ?? resolvedAuthorID ?? context.authorID,
            initialResumePoint: chapter?.resumePoint,
            forumID: threadPage?.forumID ?? threadPage?.thread.fid ?? context.thread.fid
        )
    }

    func continueLaunchContext() -> NovelLaunchContext {
        let novelProgress = readingProgress?.novel
        let position = NovelReadingResumeResolver.resolve(
            progress: novelProgress, fallbackView: 1, fallbackAuthorID: resolvedAuthorID ?? context.authorID
        )
        let hasProgress = Self.hasReadingProgress(readingProgress, favorite: favoriteActions.favorite)
        return NovelLaunchContext(
            threadID: context.thread.tid,
            threadTitle: favoriteActions.favorite?.resolvedDisplayTitle ?? context.title,
            source: hasProgress ? .resume : .forum,
            initialView: position.view,
            authorID: position.authorID,
            initialResumePoint: position.resumePoint,
            forumID: threadPage?.forumID ?? threadPage?.thread.fid ?? context.thread.fid
        )
    }

    func toggleChapterSection(page: Int) async {
        let normalizedPage = max(1, page)
        if expandedChapterPages.contains(normalizedPage) {
            expandedChapterPages.remove(normalizedPage)
            rebuildChapterDirectory()
            return
        }

        expandedChapterPages.insert(normalizedPage)
        rebuildChapterDirectory()
        guard loadedThreadPages[normalizedPage] == nil else { return }
        await loadChapterSection(page: normalizedPage)
    }

    func loadChapterSection(page: Int) async {
        let normalizedPage = max(1, page)
        guard loadedThreadPages[normalizedPage] == nil,
              !loadingChapterPages.contains(normalizedPage) else {
            return
        }

        loadingChapterPages.insert(normalizedPage)
        let generation = contentGeneration
        chapterPageErrors[normalizedPage] = nil
        chapterPageErrorDetails[normalizedPage] = nil
        rebuildChapterDirectory()
        defer {
            if contentGeneration == generation {
                loadingChapterPages.remove(normalizedPage)
                rebuildChapterDirectory()
            }
        }

        do {
            let repository = await dependencies.makeForumThreadReaderRepository()
            let authorID = try Self.resolveAuthorID(context: context, page: threadPage)
            resolvedAuthorID = authorID
            let contentContext = authorScopedContext(authorID: authorID)
            let loaded = if let cached = await repository.cachedNovelThreadPage(context: contentContext, page: normalizedPage) {
                cached
            } else {
                try await repository.fetchNovelThreadPage(context: contentContext, page: normalizedPage)
            }
            let projectionRepository = await dependencies.makeNovelReaderRepository()
            let projection = try? await projectionRepository.projection(
                from: loaded,
                request: NovelPageRequest(threadID: context.thread.tid, view: normalizedPage, authorID: authorID)
            )
            let summaries = if let projection {
                await Self.summariesOffMainActor(from: loaded, document: projection, settings: novelReaderSettings)
            } else {
                [NovelChapterSummary]()
            }
            try Task.checkCancellation()
            guard contentGeneration == generation else { return }
            loadedThreadPages[normalizedPage] = loaded
            pageChapterSummaries[normalizedPage] = summaries
            totalChapterPages = max(totalChapterPages, Self.totalPages(from: loaded, fallback: normalizedPage))
            chapterPageErrors[normalizedPage] = nil
            chapterPageErrorDetails[normalizedPage] = nil
        } catch {
            guard contentGeneration == generation, !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            chapterPageErrors[normalizedPage] = error.localizedDescription
            chapterPageErrorDetails[normalizedPage] = LoadFailureDetails(error: error)
        }
    }

    static func chapterSections(
        from loadedPages: [Int: ForumThreadPage],
        totalPages: Int,
        loadingPages: Set<Int> = [],
        pageErrors: [Int: String] = [:],
        pageErrorDetails: [Int: LoadFailureDetails] = [:],
        readingProgress: ReadingProgressRecord? = nil,
        favorite: Favorite? = nil,
        novelReaderSettings: NovelReaderAppearanceSettings = .init(),
        authorID: String? = nil,
        preparedSummaries: [Int: [NovelChapterSummary]]? = nil
    ) -> [NovelChapterSection] {
        let normalizedTotal = max(1, totalPages)
        return (1...normalizedTotal).map { page in
            let pageDocument = loadedPages[page]
            let chapters = preparedSummaries?[page] ?? (preparedSummaries == nil ? pageDocument.map {
                chapterSummaries(
                    from: $0,
                    page: page,
                    novelReaderSettings: novelReaderSettings,
                    authorID: authorID
                )
            } ?? [] : [])
            let currentReadIndex = currentReadChapterIndex(
                in: chapters,
                readingProgress: readingProgress,
                favorite: favorite
            )
            return NovelChapterSection(
                page: page,
                chapters: chapters.enumerated().map { index, chapter in
                    var updatedChapter = chapter
                    updatedChapter.progressText = chapterProgressText(
                        for: chapter,
                        readingProgress: readingProgress,
                        favorite: favorite
                    )
                    updatedChapter.isCurrentRead = index == currentReadIndex
                    return updatedChapter
                },
                isLoaded: pageDocument != nil,
                isLoading: loadingPages.contains(page),
                errorMessage: pageErrors[page],
                errorDetails: pageErrorDetails[page]
            )
        }
    }

    private func rebuildChapterDirectory() {
        guard isVisible else {
            directoryNeedsRefresh = true
            return
        }
        directoryNeedsRefresh = false
        chapterSections = Self.chapterSections(
            from: loadedThreadPages,
            totalPages: totalChapterPages,
            loadingPages: loadingChapterPages,
            pageErrors: chapterPageErrors,
            pageErrorDetails: chapterPageErrorDetails,
            readingProgress: readingProgress,
            favorite: favoriteActions.favorite,
            novelReaderSettings: novelReaderSettings,
            authorID: resolvedAuthorID ?? context.authorID,
            preparedSummaries: pageChapterSummaries
        )
        chapters = chapterSections.flatMap(\.chapters)
    }

    func refreshContentCover(from page: ForumThreadPage) async {
        guard let key = contentCoverKey else { return }
        let generation = contentGeneration
        if let candidate = ThreadCoverResolver.findThreadCoverCandidate(in: page) {
            do {
                _ = try await dependencies.contentCoverStore.setAutomaticCover(candidate, for: key)
            } catch {
                YamiboLog.library.error("Failed to set automatic cover for \(String(describing: key)): \(error)")
                return
            }
        }
        let cover = await dependencies.contentCoverStore.cover(for: key)
        guard !Task.isCancelled, contentGeneration == generation else { return }
        contentCover = cover
    }

    private static func chapterSummaries(
        from page: ForumThreadPage,
        page pageNumber: Int,
        novelReaderSettings: NovelReaderAppearanceSettings,
        authorID: String?
    ) -> [NovelChapterSummary] {
        let resolvedAuthorID = authorID?.nilIfBlank ?? page.posts.first?.author.uid?.nilIfBlank
        guard let resolvedAuthorID else { return [] }
        let request = NovelPageRequest(
            threadID: page.thread.tid,
            view: pageNumber,
            authorID: resolvedAuthorID
        )
        guard let document = try? NovelReaderProjectionBuilder.build(
            from: page,
            request: request,
            authorID: resolvedAuthorID
        ) else {
            YamiboLog.forum.warning("Failed to build novel reader projection for thread \(page.thread.tid) page \(pageNumber); returning empty chapter list")
            return []
        }
        return summaries(from: page, document: document, settings: novelReaderSettings)
    }

    private nonisolated static func summariesOffMainActor(
        from page: ForumThreadPage, document: NovelReaderProjection, settings: NovelReaderAppearanceSettings
    ) async -> [NovelChapterSummary] {
        let task = Task.detached {
            guard !Task.isCancelled else { return [NovelChapterSummary]() }
            return summaries(from: page, document: document, settings: settings)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func summaries(
        from page: ForumThreadPage, document: NovelReaderProjection, settings: NovelReaderAppearanceSettings
    ) -> [NovelChapterSummary] {
        let pageNumber = document.view
        let floorTextByPostID = page.posts.reduce(into: [String: String]()) { partial, post in
            guard let postID = post.postID.nilIfBlank,
                  let floorText = post.floorText else {
                return
            }
            partial[postID] = floorText
        }
        return NovelChapterDirectoryExtractor
            .entries(from: document, settings: settings)
            .map { entry in
                let postID = entry.ownerPostID
                return NovelChapterSummary(
                    id: "\(pageNumber)|\(postID ?? String(entry.chapter.ordinal))",
                    title: entry.chapter.title,
                    view: pageNumber,
                    postID: postID,
                    floorText: postID.flatMap { floorTextByPostID[$0] },
                    resumePoint: entry.anchor?.resumePoint
                )
            }
    }

    private static func totalPages(from page: ForumThreadPage, fallback: Int) -> Int {
        max(fallback, page.pageNavigation?.totalPages ?? page.pageNavigation?.currentPage ?? fallback)
    }

    private var forumName: String? {
        if let forumName = threadPage?.forumName?.nilIfBlank {
            return forumName
        }
        guard let fid = threadPage?.thread.fid?.nilIfBlank
            ?? context.thread.fid?.nilIfBlank else {
            return nil
        }
        return fid
    }

    private var favoriteTitle: String {
        displayTitle(threadPage?.title ?? context.title)
    }

    private static func contentUpdatedAt(from page: ForumThreadPage?) -> Date? {
        guard let firstPost = page?.posts.first else { return nil }
        return FavoriteContentUpdateDateResolver.date(
            lastEditedText: firstPost.lastEditedText,
            postedAtText: firstPost.postedAtText
        )
    }

    private func authorScopedContext(authorID: String) -> NovelDetailLaunchContext {
        NovelDetailLaunchContext(
            thread: context.thread,
            title: context.title,
            authorID: authorID
        )
    }

    private func displayTitle(_ value: String?) -> String {
        ForumThreadTitleSanitizer.sanitize(value)
            ?? context.thread.tid
    }

    private static func resolveAuthorID(context: NovelDetailLaunchContext, page: ForumThreadPage?) throws -> String {
        if let authorID = context.authorID?.nilIfBlank {
            return authorID
        }
        if let authorID = page?.posts.first?.author.uid?.nilIfBlank {
            return authorID
        }
        throw YamiboError.parsingFailed(context: L10n.string("parsing_context.novel_author_scope"))
    }

    private static func firstFloorPreviewText(from post: ForumThreadPost?) -> String? {
        guard let post else { return nil }
        let text = post.contentText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.nilIfBlank
    }

    private static func readingProgressText(from readingProgress: ReadingProgressRecord?, favorite: Favorite?) -> String? {
        if let novel = readingProgress?.novel,
           hasReadingProgress(readingProgress, favorite: nil) {
            return readingProgressText(from: novel)
        }
        return nil
    }

    private static func readingProgressText(from novel: NovelReadingProgressRecord) -> String {
        if let chapterTitle = novel.novelResumePoint?.chapterTitle?.nilIfBlank
            ?? novel.lastChapter?.nilIfBlank {
            return chapterTitle
        }
        if let percent = novel.novelDocumentSurfaceProgressPercent {
            if let maxView = novel.novelMaxView, maxView > 1 {
                return L10n.string(
                    "favorites.progress.novel_page_web",
                    percent,
                    min(max(novel.lastView, 1), maxView),
                    maxView
                )
            }
            return L10n.string("favorites.progress.novel_percent", percent)
        }
        if let maxView = novel.novelMaxView, maxView > 1 {
            return L10n.string(
                "favorites.progress.novel_web",
                min(max(novel.lastView, 1), maxView),
                maxView
            )
        }
        return L10n.string("favorites.progress.page", novel.lastView)
    }

    private static func chapterProgressText(
        for chapter: NovelChapterSummary,
        readingProgress: ReadingProgressRecord?,
        favorite: Favorite?
    ) -> String? {
        nil
    }

    /// Finds at most one chapter to flag as the current read position, preferring a
    /// stable per-floor identity match. The title/view fallback only applies when no
    /// identity is available at all, and only ever returns the first matching chapter,
    /// so floors that share an identical extracted title are never all marked at once.
    private static func currentReadChapterIndex(
        in chapters: [NovelChapterSummary],
        readingProgress: ReadingProgressRecord?,
        favorite: Favorite?
    ) -> Int? {
        let novel = readingProgress?.novel
        let resumePoint = novel?.novelResumePoint

        if let resumeIdentity = resumePoint?.chapterIdentity {
            if let index = chapters.firstIndex(where: { $0.resumePoint?.chapterIdentity == resumeIdentity }) {
                return index
            }
            return chapters.firstIndex { chapter in
                guard let postID = chapter.postID else { return false }
                return resumeIdentity.rawValue.hasPrefix("post:\(postID)#")
            }
        }

        guard let lastView = novel?.lastView,
              let lastChapter = novel?.lastChapter?.nilIfBlank else {
            return nil
        }
        return chapters.firstIndex { chapter in
            lastView == chapter.view && chapter.title.nilIfBlank == lastChapter
        }
    }

    private static func hasReadingProgress(_ readingProgress: ReadingProgressRecord?, favorite: Favorite?) -> Bool {
        if let novel = readingProgress?.novel {
            return novel.novelResumePoint != nil
                || novel.lastView > 1
                || novel.lastChapter?.nilIfBlank != nil
                || novel.authorID?.nilIfBlank != nil
                || novel.novelMaxView != nil
                || novel.novelDocumentSurfaceProgressPercent != nil
        }
        return false
    }


    private var contentCoverKey: ContentCoverKey? {
        let tid = context.thread.tid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty else { return nil }
        return .thread(tid: tid)
    }

    private func loadContentCover() async -> ContentCover? {
        guard let key = contentCoverKey else { return nil }
        return await dependencies.contentCoverStore.cover(for: key)
    }

    private static func lastUpdatedText(editedText: String?, postedAtText: String?) -> String? {
        guard let editedText = editedText?.nilIfBlank else {
            return postedAtText?.nilIfBlank
        }
        return extractedEditTime(from: editedText) ?? editedText
    }

    private static func extractedEditTime(from text: String) -> String? {
        let patterns = [
            #"(?:本帖最后由|本帖最後由)\s+.+?\s+(?:于|於)\s+(.+?)\s+(?:编辑|編輯)"#,
            #"(?:最后编辑于|最後編輯於)\s*(.+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let searchRange = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: searchRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text),
                  let value = String(text[range]).nilIfBlank else {
                continue
            }
            return value
        }
        return nil
    }
}
