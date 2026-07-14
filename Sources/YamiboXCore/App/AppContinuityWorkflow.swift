import Foundation
import os

public struct AppContinuityLaunchResult: Sendable {
    public let bootstrapState: YamiboBootstrapState
    public let restoredRoute: ReaderResumeRoute?

    public init(bootstrapState: YamiboBootstrapState, restoredRoute: ReaderResumeRoute?) {
        self.bootstrapState = bootstrapState
        self.restoredRoute = restoredRoute
    }
}

/// Thread-agnostic: mutable state sits behind an unfair lock so the
/// fire-and-forget lifecycle entry points stay synchronous and, for any single
/// caller, strictly ordered (presented → position changed → dismissed).
public final class AppContinuityWorkflow: Sendable {
    private struct MutableState {
        var foregroundSyncTask: Task<Void, Never>?
        var debouncedUploadTask: Task<Void, Never>?
        var isWebDAVSyncInProgress = false
        var hasRestoredReaderResumeRoute = false
        var isReaderRoutePresented = false
    }

    private let appContext: YamiboAppContext
    private let state = OSAllocatedUnfairLock(initialState: MutableState())

    public init(appContext: YamiboAppContext) {
        self.appContext = appContext
    }

    public func launchIfNeeded(canRestoreReaderRoute: Bool) async -> AppContinuityLaunchResult {
        let bootstrapState = await appContext.bootstrap()
        let didDownloadRemoteProgress = await synchronizeWebDAVForStartup()
        let restoredRoute = await restoreExplicitly(
            canRestoreReaderRoute: canRestoreReaderRoute,
            reconcilesWithReadingProgress: didDownloadRemoteProgress
        )
        return AppContinuityLaunchResult(bootstrapState: bootstrapState, restoredRoute: restoredRoute)
    }

    public func restoreExplicitly(
        canRestoreReaderRoute: Bool,
        reconcilesWithReadingProgress: Bool = false
    ) async -> ReaderResumeRoute? {
        let isFirstRestore = state.withLock { mutableState in
            if mutableState.hasRestoredReaderResumeRoute { return false }
            mutableState.hasRestoredReaderResumeRoute = true
            return true
        }
        guard isFirstRestore else { return nil }
        guard canRestoreReaderRoute else { return nil }
        guard let route = await appContext.readerResumeRouteStore.load() else { return nil }

        guard let restoredRoute = await restorableRoute(
            from: route,
            reconcilesWithReadingProgress: reconcilesWithReadingProgress
        ) else {
            await appContext.readerResumeRouteStore.clear()
            return nil
        }

        if restoredRoute != route {
            do {
                try await appContext.readerResumeRouteStore.save(restoredRoute)
            } catch {
                YamiboLog.persistence.error("Failed to save reconciled reader resume route after restore: \(error)")
            }
        }
        state.withLock { $0.isReaderRoutePresented = true }
        return restoredRoute
    }

    public func foregroundBecameActive() {
        replaceForegroundSyncTask(
            with: Task { [weak self] in
                _ = await self?.synchronizeWebDAVSilently()
            }
        )
    }

    // `touchesAppSettings` no longer changes behavior (markLocalDataChanged now
    // fingerprints every dirty-tracked participant unconditionally — see its
    // doc comment) but the parameter stays for source compatibility with
    // existing call sites.
    public func localDataChanged(touchesAppSettings _: Bool = false) {
        guard state.withLock({ !$0.isWebDAVSyncInProgress }) else { return }
        replaceDebouncedUploadTask(
            with: Task { [weak self] in
                guard let self else { return }
                do {
                    // Marking + fingerprinting is deferred past the debounce sleep so a
                    // burst of local changes (e.g. rapid page turns) costs one
                    // UserDefaults rewrite + fingerprint pass per quiet window instead
                    // of one per change; `willEnterBackground` marks synchronously
                    // before its own flush so backgrounding mid-debounce still syncs
                    // fresh state.
                    try await Task.sleep(for: .seconds(2))

                    let service = appContext.makeWebDAVSyncService()
                    try await service.markLocalDataChanged()

                    guard beginWebDAVSync() else { return }
                    defer { endWebDAVSync() }

                    try await service.synchronizeAutomatically()
                } catch {
                    // Keep local data authoritative until the next foreground or manual sync.
                    YamiboLog.sync.warning("Debounced local-change WebDAV upload failed: \(error)")
                }
            }
        )
    }

    public func willEnterBackground() {
        replaceDebouncedUploadTask(with: nil)
        Task { [weak self] in
            await self?.flushWebDAVSyncBeforeBackground()
        }
    }

    public func readerRoutePresented(_ route: ReaderResumeRoute) {
        state.withLock { $0.isReaderRoutePresented = true }
        Task { [appContext] in
            do {
                try await appContext.readerResumeRouteStore.save(route)
            } catch {
                YamiboLog.persistence.error("Failed to save presented reader resume route: \(error)")
            }
        }
    }

    public func readerRouteDismissed() {
        state.withLock { $0.isReaderRoutePresented = false }
        appContext.readerResumeRouteStore.clearSync()
    }

    public func readerReadingPositionChanged(_ route: ReaderResumeRoute) {
        guard state.withLock({ $0.isReaderRoutePresented }) else { return }
        Task { [appContext] in
            do {
                try await appContext.readerResumeRouteStore.saveReadingPosition(route)
            } catch {
                YamiboLog.persistence.error("Failed to save reader reading position: \(error)")
            }
        }
    }

    private func replaceForegroundSyncTask(with task: Task<Void, Never>?) {
        let previous = state.withLock { mutableState in
            let previous = mutableState.foregroundSyncTask
            mutableState.foregroundSyncTask = task
            return previous
        }
        previous?.cancel()
    }

    private func replaceDebouncedUploadTask(with task: Task<Void, Never>?) {
        let previous = state.withLock { mutableState in
            let previous = mutableState.debouncedUploadTask
            mutableState.debouncedUploadTask = task
            return previous
        }
        previous?.cancel()
    }

    private func beginWebDAVSync() -> Bool {
        state.withLock { mutableState in
            if mutableState.isWebDAVSyncInProgress { return false }
            mutableState.isWebDAVSyncInProgress = true
            return true
        }
    }

    private func endWebDAVSync() {
        state.withLock { $0.isWebDAVSyncInProgress = false }
    }

    private func synchronizeWebDAVForStartup() async -> Bool {
        replaceForegroundSyncTask(with: nil)
        let result = await synchronizeWebDAVSilently()
        if case .downloaded = result {
            return true
        }
        return false
    }

    private func synchronizeWebDAVSilently() async -> WebDAVAutomaticSyncResult {
        guard beginWebDAVSync() else { return .skipped }
        defer { endWebDAVSync() }

        do {
            // Foreground activation is an infrequent, natural checkpoint, so it
            // always syncs regardless of the minimum automatic-sync interval.
            return try await appContext.makeWebDAVSyncService().synchronizeAutomatically(bypassingMinimumInterval: true)
        } catch {
            // Automatic sync should never block the app shell.
            YamiboLog.sync.warning("Automatic WebDAV sync failed: \(error)")
            return .skipped
        }
    }

    private func flushWebDAVSyncBeforeBackground() async {
        guard beginWebDAVSync() else { return }
        defer { endWebDAVSync() }

        do {
            // Marks dirty state synchronously here (rather than relying on the
            // debounced task, which this call site's caller already cancelled) so
            // edits made just before backgrounding aren't left unmarked until some
            // unrelated later change happens to trigger markLocalDataChanged again.
            let service = appContext.makeWebDAVSyncService()
            try await service.markLocalDataChanged()
            try await service.synchronizeAutomatically(bypassingMinimumInterval: true)
        } catch {
            // Background flush is best effort.
            YamiboLog.sync.warning("Background WebDAV sync flush failed: \(error)")
        }
    }

    private func restorableRoute(
        from route: ReaderResumeRoute,
        reconcilesWithReadingProgress: Bool
    ) async -> ReaderResumeRoute? {
        if reconcilesWithReadingProgress {
            if let route = await routeReconciledWithReadingProgress(route) {
                return route
            }
        }
        if route.hasLocalReadingProgress {
            return route
        }
        if !reconcilesWithReadingProgress {
            return await routeReconciledWithReadingProgress(route)
        }
        return nil
    }

    private func routeReconciledWithReadingProgress(_ route: ReaderResumeRoute) async -> ReaderResumeRoute? {
        switch route {
        case let .novel(context):
            if let progress = await appContext.readingProgressStore.load(threadID: context.threadID),
               progress.hasNovelReadingProgress {
                return .novel(context.reconciledWithReadingProgress(
                    progress,
                    favoriteItem: await favoriteItem(forThreadID: context.threadID)
                ))
            }
            return nil
        case let .manga(context):
            // Smart Comic Mode off means this thread is treated exactly like a normal
            // thread (smart-comic-mode-design-decisions #2's 总原则): its progress lives
            // ONLY in the precise per-thread `.mangaThread` record. The coincidental
            // `load(threadID:)` OR-match (thread_id = ? OR manga_chapter_thread_id = ?)
            // can otherwise pick up an unrelated directory-level `.mangaTitle` row whose
            // `manga_chapter_thread_id` happens to equal this thread id, silently
            // reconciling the restored route onto a different forum thread.
            let progress = context.isSmartModeEnabled
                ? await appContext.readingProgressStore.load(threadID: context.originalThreadID)
                : await appContext.readingProgressStore.load(for: .mangaThread(threadID: context.originalThreadID))
            if let progress, progress.hasMangaReadingProgress {
                return .manga(context.reconciledWithReadingProgress(
                    progress,
                    favoriteItem: await favoriteItem(forMangaContext: context)
                ))
            }
            return nil
        }
    }

    private func favoriteItem(forThreadID threadID: String) async -> FavoriteItem? {
        let target = FavoriteItemTarget.novelThread(threadID: threadID)
        return (try? await appContext.localFavoriteLibraryStore.load())?.items.first { item in
            item.target.id == target.id || item.target.threadID == target.threadID
        }
    }

    private func favoriteItem(forMangaContext context: MangaLaunchContext) async -> FavoriteItem? {
        guard let document = try? await appContext.localFavoriteLibraryStore.load() else { return nil }
        // A `.mangaThread` favorite is keyed by its own chapter thread id now
        // (no merged-directory identity left to look up by directoryName —
        // smart-comic-mode Phase A decision #3/#9), so a direct threadID
        // match is the only lookup that still applies.
        return document.items.first { item in
            item.target.threadID == context.originalThreadID
        }
    }
}

private extension ReaderResumeRoute {
    var hasLocalReadingProgress: Bool {
        switch self {
        case let .novel(context):
            context.hasLocalReadingProgress
        case let .manga(context):
            context.hasLocalReadingProgress
        }
    }
}

private extension NovelLaunchContext {
    var hasLocalReadingProgress: Bool {
        initialResumePoint != nil || (initialView ?? 1) > 1
    }
}

private extension MangaLaunchContext {
    var hasLocalReadingProgress: Bool {
        initialPage > 0 || chapterTID != originalThreadID || chapterView > 1
    }
}

private extension ReadingProgressRecord {
    var hasNovelReadingProgress: Bool {
        guard let novel else { return false }
        return novel.novelResumePoint != nil ||
            novel.lastView > 1 ||
            novel.lastChapter != nil ||
            novel.authorID != nil ||
            novel.novelMaxView != nil ||
            novel.novelDocumentSurfaceProgressPercent != nil
    }

    var hasMangaReadingProgress: Bool {
        manga != nil
    }
}

private extension NovelLaunchContext {
    func reconciledWithReadingProgress(
        _ progress: ReadingProgressRecord,
        favoriteItem: FavoriteItem?
    ) -> NovelLaunchContext {
        let novel = progress.novel
        let resumePoint = novel?.novelResumePoint ?? initialResumePoint
        return NovelLaunchContext(
            threadID: threadID,
            threadTitle: favoriteItem?.resolvedDisplayTitle ?? threadTitle,
            source: .resume,
            initialView: resumePoint?.view ?? novel?.lastView ?? initialView,
            authorID: resumePoint?.authorID ?? novel?.authorID ?? authorID,
            initialResumePoint: resumePoint,
            isPreview: isPreview
        )
    }
}

private extension MangaLaunchContext {
    func reconciledWithReadingProgress(
        _ progress: ReadingProgressRecord,
        favoriteItem: FavoriteItem?
    ) -> MangaLaunchContext {
        guard let manga = progress.manga else { return self }
        return MangaLaunchContext(
            originalThreadID: originalThreadID,
            chapterTID: manga.chapterThreadID,
            displayTitle: favoriteItem?.resolvedDisplayTitle ?? displayTitle,
            source: .resume,
            chapterView: manga.chapterView,
            initialPage: manga.mangaPageIndex,
            directoryName: directoryName,
            offlineCacheFavoriteID: favoriteItem?.id ?? offlineCacheFavoriteID,
            isPreview: isPreview,
            isSmartModeEnabled: isSmartModeEnabled,
            forumID: forumID
        )
    }
}
