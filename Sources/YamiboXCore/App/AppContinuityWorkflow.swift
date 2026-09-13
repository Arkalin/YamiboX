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
        var readerRouteGeneration = UUID()
    }

    private struct StartupReaderRestore {
        let route: ReaderResumeRoute?
        let routeGeneration: UUID
        let accountGeneration: UUID?
    }

    private let appContext: YamiboAppContext
    private let readerResumeRouteStore: ReaderResumeRouteStore
    private let state = OSAllocatedUnfairLock(initialState: MutableState())

    public init(appContext: YamiboAppContext, readerResumeRouteStore: ReaderResumeRouteStore? = nil) {
        self.appContext = appContext
        self.readerResumeRouteStore = readerResumeRouteStore ?? appContext.readerResumeRouteStore
    }

    public func launchIfNeeded(
        canRestoreReaderRoute: Bool,
        onProgress: @Sendable (AppBootstrapPhase) async -> Void = { _ in }
    ) async -> AppContinuityLaunchResult {
        let (route, routeGeneration) = state.withLock { mutableState in
            (readerResumeRouteStore.loadSync(), mutableState.readerRouteGeneration)
        }
        let accountGeneration = try? await appContext.sessionStore.snapshot().generation
        let startup = StartupReaderRestore(route: route, routeGeneration: routeGeneration, accountGeneration: accountGeneration)
        let bootstrapState = await appContext.bootstrap(onProgress: onProgress)
        await onProgress(.synchronizingWebDAV)
        let shouldReconcileReadingProgress = await synchronizeWebDAVForStartup(
            route: canRestoreReaderRoute ? route : nil
        )
        let restoredRoute = await restoreReaderRoute(
            canRestoreReaderRoute: canRestoreReaderRoute,
            reconcilesWithReadingProgress: shouldReconcileReadingProgress,
            startup: startup,
            onProgress: onProgress
        )
        return AppContinuityLaunchResult(bootstrapState: bootstrapState, restoredRoute: restoredRoute)
    }

    public func restoreExplicitly(
        canRestoreReaderRoute: Bool,
        reconcilesWithReadingProgress: Bool = false,
        onProgress: @Sendable (AppBootstrapPhase) async -> Void = { _ in }
    ) async -> ReaderResumeRoute? {
        await restoreReaderRoute(
            canRestoreReaderRoute: canRestoreReaderRoute,
            reconcilesWithReadingProgress: reconcilesWithReadingProgress,
            startup: nil,
            onProgress: onProgress
        )
    }

    private func restoreReaderRoute(
        canRestoreReaderRoute: Bool,
        reconcilesWithReadingProgress: Bool,
        startup: StartupReaderRestore?,
        onProgress: @Sendable (AppBootstrapPhase) async -> Void
    ) async -> ReaderResumeRoute? {
        guard await isCurrentAccount(for: startup) else { return nil }
        let restoreGeneration = state.withLock { mutableState -> UUID? in
            guard isCurrentRoute(for: startup, state: mutableState) else { return nil }
            if mutableState.hasRestoredReaderResumeRoute { return nil }
            mutableState.hasRestoredReaderResumeRoute = true
            return mutableState.readerRouteGeneration
        }
        guard let restoreGeneration else { return nil }
        guard canRestoreReaderRoute else { return nil }
        await onProgress(.loadingReadingPosition)
        guard let route = await readerResumeRouteStore.load() else { return nil }
        if let startup, route != startup.route { return nil }

        guard var restoredRoute = await restorableRoute(
            from: route,
            reconcilesWithReadingProgress: reconcilesWithReadingProgress
        ) else {
            guard await isCurrentAccount(for: startup) else { return nil }
            state.withLock { mutableState in
                if mutableState.readerRouteGeneration == restoreGeneration,
                   isCurrentRoute(for: startup, state: mutableState) {
                    readerResumeRouteStore.clearSync()
                }
            }
            return nil
        }

        if case var .novel(context) = restoredRoute, context.forumID == nil {
            context.forumID = await favoriteItem(forThreadID: context.threadID)?.forumID
            restoredRoute = .novel(context)
        }

        guard await isCurrentAccount(for: startup) else { return nil }
        let finalRoute = restoredRoute
        return state.withLock { mutableState in
            // Account changes or explicit navigation can arrive during the store awaits.
            guard mutableState.readerRouteGeneration == restoreGeneration,
                  isCurrentRoute(for: startup, state: mutableState) else { return nil }
            if finalRoute != route {
                do {
                    try readerResumeRouteStore.saveSync(finalRoute)
                } catch {
                    YamiboLog.persistence.error("Failed to save reconciled reader resume route after restore: \(error)")
                }
            }
            mutableState.isReaderRoutePresented = true
            return finalRoute
        }
    }

    private func isCurrentRoute(for startup: StartupReaderRestore?, state: MutableState) -> Bool {
        guard let startup else { return true }
        return state.readerRouteGeneration == startup.routeGeneration
            && readerResumeRouteStore.loadSync() == startup.route
    }

    private func isCurrentAccount(for startup: StartupReaderRestore?) async -> Bool {
        guard let generation = startup?.accountGeneration else { return true }
        return await appContext.sessionStore.isCurrentGeneration(generation)
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
        state.withLock { mutableState in
            mutableState.isReaderRoutePresented = true
            mutableState.readerRouteGeneration = UUID()
            do {
                try readerResumeRouteStore.saveSync(route)
            } catch {
                YamiboLog.persistence.error("Failed to save presented reader resume route: \(error)")
            }
        }
    }

    public func readerRouteDismissed() {
        state.withLock { mutableState in
            mutableState.isReaderRoutePresented = false
            mutableState.readerRouteGeneration = UUID()
            readerResumeRouteStore.clearSync()
        }
    }

    public func readerReadingPositionChanged(_ route: ReaderResumeRoute) {
        state.withLock { mutableState in
            guard mutableState.isReaderRoutePresented else { return }
            do {
                try readerResumeRouteStore.saveReadingPositionSync(route)
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

    private func synchronizeWebDAVForStartup(route: ReaderResumeRoute?) async -> Bool {
        replaceForegroundSyncTask(with: nil)
        let before = await observeReadingProgress(for: route)
        let result = await synchronizeWebDAVSilently()
        let after = await observeReadingProgress(for: route)
        // A merge commits locally before PUT, so even a failed upload can
        // change the resume position. Unrelated datasets must not move it.
        if case let .success(previous) = before,
           case let .success(current?) = after,
           let route, current.hasReadingProgress(for: route) {
            return previous != current
        }
        return result == .downloaded
    }

    private func observeReadingProgress(for route: ReaderResumeRoute?) async -> Result<ReadingProgressRecord?, any Error> {
        guard let route else { return .success(nil) }
        do {
            return .success(try await readingProgress(for: route))
        } catch {
            YamiboLog.persistence.warning("Failed to observe startup reading progress; falling back to sync direction: \(error)")
            return .failure(error)
        }
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
        let progress: ReadingProgressRecord
        do {
            guard let record = try await readingProgress(for: route), record.hasReadingProgress(for: route) else { return nil }
            progress = record
        } catch {
            YamiboLog.persistence.warning("Failed to read progress while reconciling reader route: \(error)")
            return nil
        }
        switch route {
        case let .novel(context):
            return .novel(context.reconciledWithReadingProgress(
                progress,
                favoriteItem: await favoriteItem(forThreadID: context.threadID)
            ))
        case let .manga(context):
            return .manga(context.reconciledWithReadingProgress(
                progress,
                favoriteItem: await favoriteItem(forMangaContext: context)
            ))
        }
    }

    private func readingProgress(for route: ReaderResumeRoute) async throws -> ReadingProgressRecord? {
        switch route {
        case let .novel(context):
            return try await appContext.readingProgressStore.loadThrowing(threadID: context.threadID)
        case let .manga(context):
            // Smart Comic Mode off means this thread is treated exactly like a normal
            // thread (smart-comic-mode-design-decisions #2's 总原则): its progress lives
            // ONLY in the precise per-thread `.mangaThread` record. The coincidental
            // `load(threadID:)` OR-match (thread_id = ? OR manga_chapter_thread_id = ?)
            // can otherwise pick up an unrelated directory-level `.mangaTitle` row whose
            // `manga_chapter_thread_id` happens to equal this thread id, silently
            // reconciling the restored route onto a different forum thread.
            if context.isSmartModeEnabled {
                return try await appContext.readingProgressStore.loadThrowing(threadID: context.originalThreadID)
            }
            return try await appContext.readingProgressStore.loadThrowing(for: .mangaThread(threadID: context.originalThreadID))
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
    func hasReadingProgress(for route: ReaderResumeRoute) -> Bool {
        switch route {
        case .novel: hasNovelReadingProgress
        case .manga: hasMangaReadingProgress
        }
    }

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
            isPreview: isPreview,
            forumID: forumID
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
