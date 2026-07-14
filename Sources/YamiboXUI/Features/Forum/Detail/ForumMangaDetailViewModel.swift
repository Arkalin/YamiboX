import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class ForumMangaDetailViewModel {
    var directory: MangaDirectory?
    var currentDocument: MangaReaderProjection?
    var readingProgress: ReadingProgressRecord?
    var contentCover: ContentCover?
    var isLoading = false
    var errorMessage: String?

    /// Directory command surface mirroring the reader directory sheet's
    /// update/search button: a single in-flight flag shared by "update
    /// directory" and "save correction" (they mutate the same directory row),
    /// plus the search-cooldown countdown and the short post-update window in
    /// which the button escalates to a forced global search.
    var isDirectoryActionRunning = false
    var directoryCooldownRemaining = 0
    var forcedSearchShortcutRemaining: Int?
    var directoryActionErrorMessage: String?

    /// Favorite-star state and actions (add/remove/relocate prompts, location
    /// picker, transient feedback) — shared orchestration with the novel
    /// detail page.
    let favoriteActions: FavoriteActionController

    let context: MangaDetailLaunchContext

    @ObservationIgnored private let dependencies: ForumDependencies
    @ObservationIgnored private var readingProgressUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var contentCoverUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var mangaDirectoryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var automaticDirectoryUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCoverResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedAutomaticCoverBookNames: Set<String> = []
    @ObservationIgnored private var directoryTickTask: Task<Void, Never>?
    @ObservationIgnored private let workflowConfiguration: MangaDirectoryWorkflowConfiguration
    @ObservationIgnored private let makeThreadCoverPageRepository: @Sendable () async -> any ThreadCoverPageResolving

    init(
        context: MangaDetailLaunchContext,
        dependencies: ForumDependencies,
        workflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        // Test seam mirroring `MangaReaderDependencies.makeThreadCoverPageRepository`:
        // the default resolves covers through the real forum thread reader
        // repository, which tests must not reach over the network.
        makeThreadCoverPageRepository: (@Sendable () async -> any ThreadCoverPageResolving)? = nil
    ) {
        self.context = context
        self.dependencies = dependencies
        favoriteActions = FavoriteActionController(
            threadID: context.thread.tid,
            type: .manga,
            defaultTitle: context.title,
            dependencies: dependencies
        )
        // Stamp the launching board's fid over the injected configuration
        // (mirroring MangaReaderViewModel's construction): the detail page's
        // 更新目录 action reaches `workflow.updateDirectory` → search, which
        // must query THIS board — never the test-convenience default "30"
        // (pluggable-reader-config decision #6). A fid-less route (routing
        // always sets one today) keeps the injected configuration's own
        // value, i.e. exactly the pre-stamping behavior.
        var configuration = workflowConfiguration
        if let fid = context.thread.fid {
            configuration.searchForumID = fid
        }
        self.workflowConfiguration = configuration
        self.makeThreadCoverPageRepository = makeThreadCoverPageRepository
            ?? { [makeForumThreadReaderRepository = dependencies.makeForumThreadReaderRepository] in
                await makeForumThreadReaderRepository()
            }
        readingProgressUpdatesTask = StoreChangeObservation.task(
            named: ReadingProgressStore.didChangeNotification,
            changeIDKey: ReadingProgressStore.changeIDUserInfoKey,
            changeID: { [store = dependencies.readingProgressStore] in store.changeID }
        ) { [weak self] in
            guard let self else { return }
            readingProgress = await self.loadReadingProgress()
        }
        contentCoverUpdatesTask = StoreChangeObservation.task(
            named: ContentCoverStore.didChangeNotification,
            changeIDKey: ContentCoverStore.changeIDUserInfoKey,
            changeID: { [store = dependencies.contentCoverStore] in store.changeID }
        ) { [weak self] in
            guard let self else { return }
            contentCover = await self.loadContentCover()
        }
        // Without this, renaming/updating this manga's directory from
        // elsewhere while this page stays open — the manga reader's own
        // directory sheet, a background smart-manga update check
        // ([[smart-manga-update-check-design]]) — would leave `directory`
        // (and the `.smartManga` cover derived from its `cleanBookName`)
        // stale until some unrelated action happened to trigger a reload.
        // Mirrors `FavoriteLibraryOrganizer.reloadMangaDirectories()`'s
        // listener for the Favorites tab.
        mangaDirectoryUpdatesTask = StoreChangeObservation.task(
            named: MangaDirectoryStore.didChangeNotification,
            changeIDKey: MangaDirectoryStore.changeIDUserInfoKey,
            changeID: { [store = dependencies.mangaDirectoryStore] in store.changeID }
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
                contentUpdatedAt: self.directory?.lastUpdatedAt
            )
        }
    }

    deinit {
        readingProgressUpdatesTask?.cancel()
        contentCoverUpdatesTask?.cancel()
        mangaDirectoryUpdatesTask?.cancel()
        automaticDirectoryUpdateTask?.cancel()
        automaticCoverResolutionTask?.cancel()
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

    var coverURL: URL? {
        contentCover?.resolvedURL
    }

    var latestChapterText: String? {
        guard let directory else { return nil }
        return MangaChapterDisplayFormatter.latestChapter(in: directory.chapters).map {
            L10n.string("manga.latest_chapter", MangaChapterDisplayFormatter.displayNumber(for: $0))
        }
    }

    var readingProgressText: String? {
        guard let manga = readingProgress?.manga else { return nil }
        if let pageCount = manga.mangaPageCount {
            return L10n.string("favorites.progress.manga_page_total", manga.lastChapter, manga.mangaPageIndex + 1, pageCount)
        }
        return L10n.string("favorites.progress.manga_page", manga.lastChapter, manga.mangaPageIndex + 1)
    }

    var currentReadChapterProgressText: String? {
        guard let manga = readingProgress?.manga else { return nil }
        return L10n.string("favorites.progress.page", manga.mangaPageIndex + 1)
    }

    /// Same title state machine as the reader directory sheet's update button
    /// (`MangaReaderWorkflow.directoryPanelPresentation`): busy → cooldown
    /// countdown → forced-search shortcut countdown → strategy-dependent
    /// default.
    var updateButtonTitle: String {
        if isDirectoryActionRunning {
            return L10n.string("common.updating")
        }
        if directoryCooldownRemaining > 0 {
            return "\(directoryCooldownRemaining)s"
        }
        if let forcedSearchShortcutRemaining {
            return forcedSearchShortcutRemaining > 0
                ? L10n.string("manga.global_search_countdown", forcedSearchShortcutRemaining)
                : L10n.string("manga.global_search")
        }
        if let directory, directory.strategy != .tag {
            return L10n.string("manga.global_search")
        }
        return L10n.string("reader.cache_action.update")
    }

    var isUpdateButtonEnabled: Bool {
        directory != nil && !isDirectoryActionRunning && directoryCooldownRemaining <= 0
    }

    var isSearchMode: Bool {
        forcedSearchShortcutRemaining != nil || (directory.map { $0.strategy != .tag } ?? false)
    }

    var editDraft: MangaDirectoryEditDraft? {
        guard let directory else { return nil }
        return makeDirectoryWorkflow().editDraft(for: directory, currentTID: focusedChapterTID)
    }

    func load() async {
        guard directory == nil else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        readingProgress = await loadReadingProgress()
        await favoriteActions.refreshFavorite()
        favoriteActions.errorMessage = nil
        defer { isLoading = false }

        do {
            let loader = await dependencies.makeMangaReaderProjectionLoader()
            let document = try await loader.loadReaderProjection(
                MangaReaderProjectionRequest(threadID: context.thread.tid)
            )
            let workflow = await makeDirectoryWorkflowWithRepository()
            let launchContext = MangaLaunchContext(
                originalThreadID: context.thread.tid,
                chapterTID: context.thread.tid,
                displayTitle: context.title,
                source: .forum,
                directoryName: context.directoryNameHint,
                // `ForumMangaDetailView` (and this view model) is only ever
                // reached via `YamiboThreadRouteTarget.manga`, which
                // `YamiboThreadRouteResolver` only produces when the board's
                // Smart Comic Mode is on — the mode-off case routes to
                // `.mangaDirect` instead and never reaches here. Hardcoding
                // `true` (rather than re-querying `AppSettings`) keeps this
                // view model from needing its own settings dependency for a
                // fact its caller already established.
                isSmartModeEnabled: true,
                forumID: context.thread.fid
            )
            let resolution = try await workflow.resolveInitialDirectory(
                context: launchContext,
                projection: document
            )
            let resolvedDirectory = try await ensuringDirectoryContainsCurrentChapter(
                resolution.directory,
                document: document,
                store: dependencies.mangaDirectoryStore
            )

            currentDocument = document
            directory = resolvedDirectory
            // Only now is `directory`'s stable identity known, so only now can
            // the precise directory-scoped query replace whatever the fuzzy
            // fetch above (before `directory` was known) happened to find.
            readingProgress = await loadReadingProgress()
            contentCover = await loadContentCover()
            if resolution.shouldAutoUpdateAfterInitialLoad {
                // The imminent directory update may rewrite the chapter
                // list (and thus which chapter is "first"), so cover
                // resolution waits for `performDirectoryUpdate` to trigger
                // it with the updated directory.
                startAutomaticDirectoryUpdate()
            } else {
                startAutomaticCoverResolutionIfNeeded()
            }
        } catch {
            currentDocument = nil
            directory = nil
            readingProgress = await loadReadingProgress()
            contentCover = nil
            errorMessage = error.localizedDescription
        }
    }

    var hasReadingProgress: Bool {
        readingProgress?.manga != nil
    }

    var isFavorited: Bool {
        favoriteActions.favorite != nil
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
            // See the comment in `reload()`: this view model only exists
            // for mode-on boards.
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
            // See the comment in `reload()`: this view model only exists
            // for mode-on boards.
            isSmartModeEnabled: true,
            forumID: context.thread.fid
        )
    }

    // MARK: - Directory update (search)

    func updateDirectoryFromDetail() async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        await performDirectoryUpdate(isForcedSearch: forcedSearchShortcutRemaining != nil)
    }

    /// Discards the locally cached directory (including manual corrections)
    /// and rebuilds it from the network, mirroring the reader directory
    /// sheet's reset action (`MangaReaderViewModel.resetDirectory`).
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
            if let cooldownExpiresAt = result.cooldownExpiresAt {
                directoryCooldownExpiresAt = cooldownExpiresAt
                forcedSearchShortcutExpiresAt = nil
            } else if result.shouldOfferForcedSearch {
                directoryCooldownExpiresAt = nil
                forcedSearchShortcutExpiresAt = workflowConfiguration.now()
                    .addingTimeInterval(workflowConfiguration.forcedSearchShortcutDuration)
            } else {
                directoryCooldownExpiresAt = nil
                forcedSearchShortcutExpiresAt = nil
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory update failed: \(error.localizedDescription)")
            if case let YamiboError.searchCooldown(seconds) = error {
                directoryCooldownExpiresAt = workflowConfiguration.now()
                    .addingTimeInterval(TimeInterval(seconds))
                forcedSearchShortcutExpiresAt = nil
            } else if let cooldown = await workflow.cooldownExpiresAt() {
                directoryCooldownExpiresAt = cooldown
                forcedSearchShortcutExpiresAt = nil
            }
            directoryActionErrorMessage = error.localizedDescription
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
            if let cooldownExpiresAt = result.cooldownExpiresAt {
                directoryCooldownExpiresAt = cooldownExpiresAt
                forcedSearchShortcutExpiresAt = nil
            } else if result.shouldOfferForcedSearch {
                directoryCooldownExpiresAt = nil
                forcedSearchShortcutExpiresAt = workflowConfiguration.now()
                    .addingTimeInterval(workflowConfiguration.forcedSearchShortcutDuration)
            } else {
                directoryCooldownExpiresAt = nil
                forcedSearchShortcutExpiresAt = nil
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory reset failed: \(error.localizedDescription)")
            if case let YamiboError.searchCooldown(seconds) = error {
                directoryCooldownExpiresAt = workflowConfiguration.now()
                    .addingTimeInterval(TimeInterval(seconds))
                forcedSearchShortcutExpiresAt = nil
            } else if let cooldown = await workflow.cooldownExpiresAt() {
                directoryCooldownExpiresAt = cooldown
                forcedSearchShortcutExpiresAt = nil
            }
            directoryActionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Favorite

    /// Title recorded when the star creates a favorite: the resolved
    /// directory's clean book name once loaded, else the launch title.
    private var favoriteTitle: String {
        directory?.cleanBookName ?? context.title
    }

    // MARK: - Correction

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
            let workflow = makeDirectoryWorkflow()
            let oldName = directory.cleanBookName
            let updated = try await workflow.renameDirectory(
                directory,
                cleanBookName: draft.cleanBookName,
                searchKeyword: MangaDirectoryWorkflow.searchKeyword(from: draft)
            )
            var cacheRenameError: Error?
            if oldName != updated.cleanBookName {
                // Mirrors the reader's rename cascade: the directory-level
                // `.mangaTitle` reading-progress row is keyed by
                // cleanBookName, and cached chapters live under an owner
                // directory named after it. (The `.smartManga` cover row is
                // migrated inside `MangaDirectoryStore.renameDirectory`.)
                do {
                    try await dependencies.readingProgressStore.migrateMangaTitleKey(from: oldName, to: updated.cleanBookName)
                } catch {
                    YamiboLog.persistence.error("Failed to migrate reading progress key after manga title rename: \(error.localizedDescription)")
                }
                if let offlineCacheStore = dependencies.mangaOfflineCacheStore {
                    do {
                        try await offlineCacheStore.renameMangaOfflineCacheOwner(from: oldName, to: updated.cleanBookName)
                    } catch {
                        YamiboLog.offlineCache.error("Failed to rename offline cache owner directory after manga rename: \(error.localizedDescription)")
                        cacheRenameError = error
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.directory = updated
            readingProgress = await loadReadingProgress()
            contentCover = await loadContentCover()
            startAutomaticCoverResolutionIfNeeded()
            directoryActionErrorMessage = cacheRenameError?.localizedDescription
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            YamiboLog.forum.error("Manga detail directory rename failed: \(error.localizedDescription)")
            directoryActionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Countdown timing

    @ObservationIgnored private var directoryCooldownExpiresAt: Date?
    @ObservationIgnored private var forcedSearchShortcutExpiresAt: Date?

    private func refreshDirectoryTiming() {
        let now = workflowConfiguration.now()
        directoryCooldownRemaining = remainingSeconds(until: directoryCooldownExpiresAt, now: now) ?? 0
        if directoryCooldownRemaining == 0 {
            directoryCooldownExpiresAt = nil
        }
        forcedSearchShortcutRemaining = remainingSeconds(until: forcedSearchShortcutExpiresAt, now: now)
        if forcedSearchShortcutRemaining == nil {
            forcedSearchShortcutExpiresAt = nil
        }
        updateDirectoryTickTask()
    }

    private func updateDirectoryTickTask() {
        let hasActiveDeadline = directoryCooldownExpiresAt != nil || forcedSearchShortcutExpiresAt != nil
        guard hasActiveDeadline else {
            directoryTickTask?.cancel()
            directoryTickTask = nil
            return
        }
        guard directoryTickTask == nil else { return }

        directoryTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = self.workflowConfiguration.now()
                self.directoryCooldownRemaining = self.remainingSeconds(until: self.directoryCooldownExpiresAt, now: now) ?? 0
                if self.directoryCooldownRemaining == 0 {
                    self.directoryCooldownExpiresAt = nil
                }
                self.forcedSearchShortcutRemaining = self.remainingSeconds(until: self.forcedSearchShortcutExpiresAt, now: now)
                if self.forcedSearchShortcutRemaining == nil {
                    self.forcedSearchShortcutExpiresAt = nil
                }
                guard self.directoryCooldownExpiresAt != nil || self.forcedSearchShortcutExpiresAt != nil else {
                    self.directoryTickTask = nil
                    return
                }
            }
        }
    }

    private func remainingSeconds(until deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining)))
    }

    // MARK: - Loading helpers

    private func makeDirectoryWorkflow() -> MangaDirectoryWorkflow {
        MangaDirectoryWorkflow(
            repository: UnreachedMangaDirectoryRepository(),
            store: dependencies.mangaDirectoryStore,
            configuration: workflowConfiguration,
            searchCooldownState: dependencies.mangaDirectorySearchCooldownState
        )
    }

    private func makeDirectoryWorkflowWithRepository() async -> MangaDirectoryWorkflow {
        MangaDirectoryWorkflow(
            repository: await dependencies.makeMangaDirectoryRepository(),
            store: dependencies.mangaDirectoryStore,
            configuration: workflowConfiguration,
            searchCooldownState: dependencies.mangaDirectorySearchCooldownState
        )
    }

    private func loadContentCover() async -> ContentCover? {
        guard let cleanBookName = directory?.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanBookName.isEmpty else {
            return nil
        }
        return await dependencies.contentCoverStore.cover(for: .smartManga(cleanBookName: cleanBookName))
    }

    /// Re-resolves `directory` (and its derived `contentCover`/
    /// `readingProgress`) in response to `MangaDirectoryStore
    /// .didChangeNotification` fired by a rename or update performed
    /// elsewhere while this page stays open. Looks the directory back up by
    /// `context.thread.tid` — stable across a rename, unlike `cleanBookName`
    /// itself (the directory's own primary key) — rather than trusting the
    /// already-loaded `directory` value, which is exactly what this handler
    /// exists to correct. Skipped while `directory` is still nil so this
    /// never races ahead of the initial `reload()`.
    private func reloadDirectoryAfterExternalChange() async {
        guard directory != nil,
              let refreshed = try? await dependencies.mangaDirectoryStore.directory(containingTID: context.thread.tid) else {
            return
        }
        directory = refreshed
        readingProgress = await loadReadingProgress()
        contentCover = await loadContentCover()
    }

    /// Resolves a missing `.smartManga` automatic cover for the loaded
    /// directory, mirroring `FavoriteLibraryOrganizer`'s backfill (smart-
    /// comic-mode decision #13): the earliest chapter's floor-1 owner image
    /// via `ThreadCoverResolver` → `setAutomaticCover`. That backfill only
    /// runs over *favorited* directories during favorites organization, so
    /// without this, a detail page opened for an unfavorited manga (or
    /// before the favorites page ever organized) never shows a cover.
    private func startAutomaticCoverResolutionIfNeeded() {
        guard automaticCoverResolutionTask == nil, let directory else { return }
        let cleanBookName = directory.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBookName.isEmpty,
              let firstChapter = directory.chapters.first,
              !attemptedAutomaticCoverBookNames.contains(cleanBookName) else {
            return
        }
        // Same missing-check as the favorites backfill: a text-cover-forced
        // row is a deliberate "no image", not a missing cover, and any
        // resolved URL means there is nothing to do.
        if let contentCover, contentCover.textCoverForced || contentCover.resolvedURL != nil {
            return
        }
        attemptedAutomaticCoverBookNames.insert(cleanBookName)
        automaticCoverResolutionTask = Task { @MainActor [weak self] in
            await self?.performAutomaticCoverResolution(cleanBookName: cleanBookName, chapterTID: firstChapter.tid)
            self?.automaticCoverResolutionTask = nil
        }
    }

    private func performAutomaticCoverResolution(cleanBookName: String, chapterTID: String) async {
        let key = ContentCoverKey.smartManga(cleanBookName: cleanBookName)
        let store = dependencies.contentCoverStore
        // Re-check right before resolving: the favorites backfill or a
        // manual cover action may have raced a cover in since this page
        // loaded its snapshot.
        if let existing = await store.cover(for: key),
           existing.textCoverForced || existing.resolvedURL != nil {
            contentCover = await loadContentCover()
            return
        }
        let repository = await makeThreadCoverPageRepository()
        guard let coverURL = await ThreadCoverResolver().resolve(
            thread: ThreadIdentity(tid: chapterTID),
            title: cleanBookName,
            repository: repository
        ) else {
            return
        }
        do {
            _ = try await store.setAutomaticCover(coverURL, for: key)
        } catch is CancellationError {
            return
        } catch {
            YamiboLog.library.error("Failed to set automatic smartManga cover from manga detail for \(cleanBookName): \(error.localizedDescription)")
            return
        }
        // `setAutomaticCover` also posts the store's change notification,
        // but reloading directly keeps this page's cover from depending on
        // notification delivery ordering.
        contentCover = await loadContentCover()
    }

    /// Once `directory` is known, its stable `mangaID`+`cleanBookName`
    /// identity is the precise lookup key for this manga's reading progress
    /// — mirrors `LocalFavoriteOpenTargetResolver.mangaDirectoryResumeTarget`.
    /// `ReadingProgressStore.saveMangaTitle` upserts a single directory-level
    /// row whose `thread_id`/`manga_chapter_thread_id` columns both hold
    /// whatever chapter tid was current *at save time* — so a chapter that
    /// was never the "current" one when that row was written can still have
    /// its own stale `.mangaThread` row sharing this same tid. The generic
    /// `load(threadID:)` OR-matches on either column and would happily
    /// return whichever row was updated most recently regardless of kind,
    /// coincidentally latching onto that stale per-chapter row instead of
    /// the directory's true current position. Before `directory` resolves
    /// there is no directory identity yet to query by, so the coincidental
    /// OR-match remains the only option in that narrow window.
    private func loadReadingProgress() async -> ReadingProgressRecord? {
        guard let directory else {
            return await dependencies.readingProgressStore.load(threadID: context.thread.tid)
        }
        let target = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
        return await dependencies.readingProgressStore.load(for: target)
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
