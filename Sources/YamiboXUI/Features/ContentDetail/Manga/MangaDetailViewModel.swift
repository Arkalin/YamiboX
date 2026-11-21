import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class MangaDetailViewModel {
    var directory: MangaDirectory?
    var currentDocument: MangaReaderProjection?
    private var currentPublicationDate: Date?
    var readingProgress: ReadingProgressRecord?
    var contentCover: ContentCover?
    var isLoading = false
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    private(set) var errorDetails: LoadFailureDetails?

    var isDirectoryActionRunning = false
    var directoryCooldownRemaining = 0
    var forcedSearchShortcutRemaining: Int?
    var directoryActionErrorMessage: String? {
        didSet { directoryActionErrorDetails = nil }
    }
    var directoryActionErrorDetails: LoadFailureDetails?

    let favoriteActions: FavoriteActionController

    let context: MangaDetailLaunchContext

    @ObservationIgnored private let dependencies: MangaDetailDependencies
    @ObservationIgnored private var readingProgressUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var contentCoverUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var mangaDirectoryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var automaticDirectoryUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCoverResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var favoriteMembershipTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedAutomaticCoverBookNames: Set<String> = []
    @ObservationIgnored private var directoryTickTask: Task<Void, Never>?
    @ObservationIgnored private let workflowConfiguration: MangaDirectoryWorkflowConfiguration

    init(
        context: MangaDetailLaunchContext,
        dependencies: MangaDetailDependencies,
        workflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration()
    ) {
        self.context = context
        self.dependencies = dependencies
        favoriteActions = FavoriteActionController(
            threadID: context.thread.tid,
            type: .manga,
            defaultTitle: context.title,
            localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
            settingsStore: dependencies.settingsStore,
            makeFavoriteRepository: dependencies.makeFavoriteRepository,
            scope: .manga(threadID: context.thread.tid, title: context.directoryNameHint ?? context.title, forumID: context.thread.fid),
            mangaDirectoryStore: dependencies.mangaDirectoryStore
        )
        var configuration = workflowConfiguration
        if let fid = context.thread.fid {
            configuration.searchForumID = fid
        }
        self.workflowConfiguration = configuration
        readingProgressUpdatesTask = StoreChangeObservation.task(
            changes: { [store = dependencies.readingProgressStore] in store.changes() }
        ) { [weak self] in
            guard let self else { return }
            await self.refreshReadingProgress()
        }
        contentCoverUpdatesTask = StoreChangeObservation.task(
            changes: { [store = dependencies.contentCoverStore] in store.changes() }
        ) { [weak self] in
            guard let self else { return }
            contentCover = await self.loadContentCover()
        }
        mangaDirectoryUpdatesTask = StoreChangeObservation.task(
            changes: { [store = dependencies.mangaDirectoryStore] in store.changes() }
        ) { [weak self] in
            await self?.reloadDirectoryAfterExternalChange()
        }
        favoriteActions.makeAddMetadata = { @MainActor [weak self] in
            guard let self else { return .init(title: context.title) }
            let boardReaderSettings = await self.dependencies.settingsStore.load().boardReader
            return .init(
                title: self.favoriteTitle,
                forumID: self.context.thread.fid,
                forumName: boardReaderSettings.entry(forumID: self.context.thread.fid)?.boardName,
                contentUpdatedAt: self.currentPublicationDate
                    ?? self.directory?.chapters.first(where: { $0.tid == self.context.thread.tid })?.publishTime
            )
        }
    }

    deinit {
        readingProgressUpdatesTask?.cancel()
        contentCoverUpdatesTask?.cancel()
        mangaDirectoryUpdatesTask?.cancel()
        automaticDirectoryUpdateTask?.cancel()
        automaticCoverResolutionTask?.cancel()
        favoriteMembershipTask?.cancel()
        directoryTickTask?.cancel()
    }

    var navigationTitle: String {
        directory?.cleanBookName ?? context.title
    }

    var focusedChapterTID: String? {
        context.focusedChapterTID ?? currentDocument?.tid
    }

    var currentReadChapterTID: String? {
        readingProgress?.manga?.chapterThreadID
    }

    var coverSource: YamiboImageSource? {
        contentCover?.resolvedImageSource
    }

    var latestChapterText: String? {
        guard let directory else { return nil }
        return MangaChapterDisplayFormatter.latestChapter(in: directory.chapters).map {
            L10n.string("manga.latest_chapter", MangaChapterDisplayFormatter.displayNumber(for: $0))
        }
    }

    var readingProgressText: String? {
        readingProgress?.manga?.lastChapter
    }

    var currentReadChapterProgressText: String? {
        guard let manga = readingProgress?.manga else { return nil }
        return L10n.string("favorites.progress.page", manga.mangaPageIndex + 1)
    }

    private var directoryCommandState: MangaDirectoryPanelCommandState {
        MangaDirectoryPanelCommandState(
            isUpdating: isDirectoryActionRunning,
            cooldownRemaining: directoryCooldownRemaining,
            forcedSearchShortcutRemaining: forcedSearchShortcutRemaining
        )
    }

    var updateButtonTitle: String {
        directoryCommandState.updateButtonTitle(strategy: directory?.strategy)
    }

    var isUpdateButtonEnabled: Bool {
        directory != nil && directoryCommandState.isUpdateButtonEnabled
    }

    var isSearchMode: Bool {
        directoryCommandState.isSearchMode(strategy: directory?.strategy)
    }

    var editDraft: MangaDirectoryEditDraft? {
        guard let directory else { return nil }
        return directoryLocalEditor.editDraft(for: directory, currentTID: focusedChapterTID)
    }

    func load() async {
        guard directory == nil else { return }
        await reload()
    }

    func refresh() async {
        await Task { await reload(ignoresCache: true) }.value
    }

    func reload(ignoresCache: Bool = false) async {
        guard !isLoading, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        favoriteActions.errorMessage = nil

        do {
            try Task.checkCancellation()
            let launchContext = MangaLaunchContext(
                originalThreadID: context.thread.tid,
                chapterTID: context.thread.tid,
                displayTitle: context.title,
                source: .forum,
                directoryName: context.directoryNameHint,
                isSmartModeEnabled: true,
                forumID: context.thread.fid
            )
            let directoryID = try await MangaReaderDirectoryResolver.resolve(
                context: launchContext, store: dependencies.mangaDirectoryStore,
                downloadStore: dependencies.mangaDownloadStore
            )
            let loader = await dependencies.makeMangaReaderProjectionLoader()
            let snapshot = try await loader.loadReaderProjectionSnapshot(
                MangaReaderProjectionRequest(threadID: context.thread.tid, offlineOwnerName: directoryID?.rawValue),
                ignoresCache: ignoresCache
            )
            let document = snapshot.projection
            let workflow = await makeDirectoryWorkflowWithRepository()
            let resolution = try await workflow.resolveInitialDirectory(
                context: launchContext,
                projection: document
            )
            let resolvedDirectory = try await ensuringDirectoryContainsCurrentChapter(
                resolution.directory,
                document: document,
                store: dependencies.mangaDirectoryStore
            )
            try Task.checkCancellation()

            currentDocument = document
            currentPublicationDate = snapshot.sourcePage.posts.first.flatMap(FavoriteContentUpdateDateResolver.publicationDate)
            directory = resolvedDirectory
            if let currentPublicationDate {
                try await dependencies.localFavoriteLibraryStore.recordContentUpdate(
                    for: .mangaThread(threadID: context.thread.tid), contentUpdatedAt: currentPublicationDate
                )
            }
            favoriteMembershipTask?.cancel()
            favoriteMembershipTask = Task { [weak self] in
                await self?.refreshFavoriteMembership()
            }
            readingProgress = try await loadReadingProgress()
            contentCover = await loadContentCover()
            if resolution.shouldAutoUpdateAfterInitialLoad {
                startAutomaticDirectoryUpdate()
            } else {
                startAutomaticCoverResolutionIfNeeded()
            }
        } catch {
            let networkError = error as NSError
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  !(networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled) else { return }
            currentDocument = nil
            directory = nil
            contentCover = nil
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    var hasReadingProgress: Bool {
        readingProgress?.manga != nil
    }

    var isFavorited: Bool {
        favoriteActions.isFavorited
    }

    func continueLaunchContext() -> MangaLaunchContext? {
        guard let directory else { return nil }
        let manga = readingProgress?.manga
        let fallbackChapter = directory.chapters.first
        let fallbackChapterTID = fallbackChapter?.tid ?? currentDocument?.tid ?? context.thread.tid
        let fallbackChapterView = fallbackChapter?.view ?? currentDocument?.sourceIdentity.view ?? 1
        return MangaLaunchContext(
            originalThreadID: context.thread.tid,
            chapterTID: manga?.chapterThreadID ?? fallbackChapterTID,
            displayTitle: directory.cleanBookName,
            source: manga == nil ? .forum : .resume,
            chapterView: manga?.chapterView ?? fallbackChapterView,
            initialPage: manga?.mangaPageIndex ?? 0,
            directoryName: directory.cleanBookName,
            directoryID: directory.id,
            isSmartModeEnabled: true,
            forumID: context.thread.fid
        )
    }

    func launchContext(for chapter: MangaChapter) -> MangaLaunchContext {
        MangaLaunchContext(
            originalThreadID: context.thread.tid,
            chapterTID: chapter.tid,
            displayTitle: directory?.cleanBookName ?? context.title,
            source: .forum,
            chapterView: chapter.view,
            directoryName: directory?.cleanBookName ?? context.directoryNameHint,
            directoryID: directory?.id,
            isSmartModeEnabled: true,
            forumID: context.thread.fid
        )
    }


    func updateDirectoryFromDetail() async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        await performDirectoryUpdate(isForcedSearch: directoryCommandState.shouldForceSearchOnUpdate)
    }

    func resetDirectoryFromDetail() async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        await performDirectoryReset()
    }

    func clearDirectoryActionError() {
        directoryActionErrorMessage = nil
    }

    private func startAutomaticDirectoryUpdate() {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = Task { @MainActor [weak self] in
            await self?.performDirectoryUpdate(isForcedSearch: false)
            self?.automaticDirectoryUpdateTask = nil
        }
    }

    private func performDirectoryUpdate(isForcedSearch: Bool) async {
        guard let directory, !isDirectoryActionRunning else { return }
        isDirectoryActionRunning = true
        directoryActionErrorMessage = nil
        defer {
            isDirectoryActionRunning = false
            refreshDirectoryTiming()
        }

        let workflow = await makeDirectoryWorkflowWithRepository()
        do {
            let result = try await workflow.updateDirectory(
                directory,
                currentTID: focusedChapterTID,
                isForcedSearch: isForcedSearch
            )
            guard !Task.isCancelled else { return }
            self.directory = result.directory
            startAutomaticCoverResolutionIfNeeded()
            directoryTiming.apply(result, configuration: workflowConfiguration)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory update failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                directoryActionErrorMessage = error.localizedDescription
                directoryActionErrorDetails = LoadFailureDetails(error: error)
                favoriteActions.transientFeedback = .failure(error)
            }
        }
    }

    private func performDirectoryReset() async {
        guard let directory, !isDirectoryActionRunning else { return }
        isDirectoryActionRunning = true
        directoryActionErrorMessage = nil
        defer {
            isDirectoryActionRunning = false
            refreshDirectoryTiming()
        }

        let workflow = await makeDirectoryWorkflowWithRepository()
        do {
            let result = try await workflow.resetDirectory(
                directory,
                seedTID: focusedChapterTID ?? context.thread.tid
            )
            guard !Task.isCancelled else { return }
            self.directory = result.directory
            startAutomaticCoverResolutionIfNeeded()
            directoryTiming.apply(result, configuration: workflowConfiguration)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory reset failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                directoryActionErrorMessage = error.localizedDescription
                directoryActionErrorDetails = LoadFailureDetails(error: error)
                favoriteActions.transientFeedback = .failure(error)
            }
        }
    }


    private func refreshFavoriteMembership() async {
        await favoriteActions.updateScope(.manga(
            threadID: context.thread.tid, title: context.title,
            forumID: context.thread.fid, directoryTitle: directory?.cleanBookName
        ))
    }

    private var favoriteTitle: String {
        directory?.cleanBookName ?? context.title
    }


    func saveCorrection(_ draft: MangaDirectoryEditDraft) async {
        guard let directory, !isDirectoryActionRunning else { return }
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        isDirectoryActionRunning = true
        directoryActionErrorMessage = nil
        defer {
            isDirectoryActionRunning = false
            refreshDirectoryTiming()
        }

        do {
            let updated = try await directoryLocalEditor.renameDirectory(
                directory,
                cleanBookName: draft.cleanBookName,
                searchKeyword: MangaDirectoryLocalEditor.searchKeyword(from: draft)
            )
            guard !Task.isCancelled else { return }
            self.directory = updated
            readingProgress = try await loadReadingProgress()
            contentCover = await loadContentCover()
            startAutomaticCoverResolutionIfNeeded()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory rename failed: \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                directoryActionErrorMessage = error.localizedDescription
                directoryActionErrorDetails = LoadFailureDetails(error: error)
                favoriteActions.transientFeedback = .failure(error)
            }
        }
    }


    @ObservationIgnored private var directoryTiming = MangaDirectoryCommandTiming()

    private func refreshDirectoryTiming() {
        publishDirectoryTiming()
        updateDirectoryTickTask()
    }

    private func publishDirectoryTiming() {
        let timing = directoryTiming.refresh(at: workflowConfiguration.now())
        directoryCooldownRemaining = timing.cooldownRemaining
        forcedSearchShortcutRemaining = timing.forcedSearchShortcutRemaining
    }

    private func applyDirectoryFailureCooldown(_ error: Error, workflow: MangaDirectoryWorkflow) async {
        let deadline = await MangaDirectoryCommandTiming.failureCooldownExpiresAt(
            for: error,
            now: workflowConfiguration.now,
            fallback: { await workflow.cooldownExpiresAt() }
        )
        directoryTiming.applyCooldown(until: deadline)
    }

    private func updateDirectoryTickTask() {
        guard directoryTiming.hasActiveDeadline else {
            directoryTickTask?.cancel()
            directoryTickTask = nil
            return
        }
        guard directoryTickTask == nil else { return }

        directoryTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.publishDirectoryTiming()
                guard self.directoryTiming.hasActiveDeadline else {
                    self.directoryTickTask = nil
                    return
                }
            }
        }
    }


    private var directoryLocalEditor: MangaDirectoryLocalEditor {
        MangaDirectoryLocalEditor(store: dependencies.mangaDirectoryStore, now: workflowConfiguration.now)
    }

    private func makeDirectoryWorkflowWithRepository() async -> MangaDirectoryWorkflow {
        MangaDirectoryWorkflow(
            repository: await dependencies.makeMangaDirectoryRepository(),
            store: dependencies.mangaDirectoryStore,
            configuration: workflowConfiguration,
            searchCooldownState: dependencies.mangaDirectorySearchCooldownState,
            downloadStore: dependencies.mangaDownloadStore
        )
    }

    private func loadContentCover() async -> ContentCover? {
        guard let directory else { return nil }
        return await dependencies.contentCoverStore.cover(for: .smartManga(directoryID: directory.id))
    }

    private func reloadDirectoryAfterExternalChange() async {
        guard let directoryID = directory?.id,
              let refreshed = try? await dependencies.mangaDirectoryStore.directory(id: directoryID) else {
            return
        }
        directory = refreshed
        await refreshFavoriteMembership()
        await refreshReadingProgress()
        contentCover = await loadContentCover()
    }

    private func startAutomaticCoverResolutionIfNeeded() {
        guard automaticCoverResolutionTask == nil, let directory else { return }
        let cleanBookName = directory.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBookName.isEmpty,
              !directory.chapters.isEmpty,
              !attemptedAutomaticCoverBookNames.contains(directory.id.rawValue) else {
            return
        }
        if let contentCover, contentCover.textCoverForced || contentCover.resolvedImageSource != nil {
            return
        }
        attemptedAutomaticCoverBookNames.insert(directory.id.rawValue)
        automaticCoverResolutionTask = Task { @MainActor [weak self] in
            await self?.performAutomaticCoverResolution(directory: directory)
            self?.automaticCoverResolutionTask = nil
        }
    }

    private func performAutomaticCoverResolution(directory: MangaDirectory) async {
        do {
            try await MangaAutomaticCoverService(store: dependencies.contentCoverStore)
                .fillMissingCover(for: directory, makeRepository: dependencies.makeForumThreadReaderRepository)
        } catch is CancellationError {
            return
        } catch {
            YamiboLog.library.error("Failed to set automatic smartManga cover from manga detail for \(directory.cleanBookName): \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }
        contentCover = await loadContentCover()
    }

    private func refreshReadingProgress() async {
        do {
            readingProgress = try await loadReadingProgress()
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            favoriteActions.transientFeedback = .failure(error)
        }
    }

    private func loadReadingProgress() async throws -> ReadingProgressRecord? {
        guard let directory else {
            return try await dependencies.readingProgressStore.load(threadID: context.thread.tid)
        }
        let target = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
        return try await dependencies.readingProgressStore.load(for: target)
    }

    private func ensuringDirectoryContainsCurrentChapter(
        _ directory: MangaDirectory,
        document: MangaReaderProjection,
        store: any MangaDirectoryPersisting
    ) async throws -> MangaDirectory {
        guard !directory.chapters.contains(where: { $0.tid == document.tid }) else {
            return directory
        }

        var updated = directory
        updated.chapters = MangaDirectoryMerge.mergeAndSort(
            directory.chapters,
            [
                MangaChapter(
                    tid: document.tid,
                    rawTitle: document.chapterTitle,
                    chapterNumber: MangaTitleCleaner.extractChapterNumber(document.chapterTitle),
                    view: document.sourceIdentity.view,
                    authorUID: document.sourceIdentity.authorID,
                    authorName: document.ownerAuthorName
                )
            ]
        )
        updated.lastUpdatedAt = Date()
        try await store.saveDirectory(updated)
        return updated
    }
}
