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

/// Local startup state is ready independently of synchronization and reader restore.
/// The completion belongs to the app, so cancelling one window's waiter does not
/// cancel a shared WebDAV round.
public struct AppContinuityLaunchPreparation: Sendable {
    public let bootstrapState: YamiboBootstrapState
    public let completion: Task<AppContinuityLaunchCompletion, Never>

    public init(bootstrapState: YamiboBootstrapState, completion: Task<AppContinuityLaunchCompletion, Never>) {
        self.bootstrapState = bootstrapState
        self.completion = completion
    }
}

public struct AppContinuityLaunchCompletion: Sendable {
    public let restoredRoute: ReaderResumeRoute?
    public let synchronizationResult: WebDAVAutomaticSyncResult

    public init(restoredRoute: ReaderResumeRoute?, synchronizationResult: WebDAVAutomaticSyncResult) {
        self.restoredRoute = restoredRoute
        self.synchronizationResult = synchronizationResult
    }
}

/// Captured before startup synchronization; each window owns its own route and
/// progress baseline, while all windows may await the same synchronization.
public struct AppContinuityReaderRestorePreparation: Sendable {
    fileprivate let route: ReaderResumeRoute?
    fileprivate let routeGeneration: UUID
    fileprivate let accountGeneration: UUID?
    fileprivate let progress: Result<ReadingProgressRecord?, any Error>
}

/// Thread-agnostic: mutable state sits behind an unfair lock so the
/// fire-and-forget lifecycle entry points stay synchronous and, for any single
/// caller, strictly ordered (presented → position changed → dismissed).
public final class AppContinuityWorkflow: Sendable {
    private struct MutableState {
        var foregroundSyncTask: Task<WebDAVAutomaticSyncResult, Never>?
        var foregroundSyncID: UUID?
        var debouncedUploadTask: Task<Void, Never>?
        var debouncedUploadID: UUID?
        var pendingChangedDatasetIDs: Set<String> = []
        var needsFullLocalFingerprint = false
        var hasFreshLocalChangeSignal = false
        var isBackgrounded = false
        var needsBackgroundFlush = false
        var isWebDAVSyncInProgress = false
        var hasRestoredReaderResumeRoute = false
        var isReaderRoutePresented = false
        var readerRouteGeneration = UUID()
    }

    private let appContext: YamiboAppContext
    private let readerResumeRouteStore: ReaderResumeRouteStore
    private let state = OSAllocatedUnfairLock(initialState: MutableState())

    public init(appContext: YamiboAppContext, readerResumeRouteStore: ReaderResumeRouteStore? = nil) {
        self.appContext = appContext
        self.readerResumeRouteStore = readerResumeRouteStore ?? appContext.readerResumeRouteStore
    }

    public func prepareLaunch(
        canRestoreReaderRoute: Bool,
        onProgress: @escaping @Sendable (AppBootstrapPhase) async -> Void = { _ in }
    ) async -> AppContinuityLaunchPreparation {
        let startup = await prepareReaderRestore()
        let bootstrapState = await appContext.bootstrap(onProgress: onProgress)
        let completion = Task { [self] in
            let synchronizationResult = await foregroundSynchronization().value
            let restoredRoute = await completeReaderRestore(
                startup,
                canRestoreReaderRoute: canRestoreReaderRoute,
                synchronizationResult: synchronizationResult
            )
            return AppContinuityLaunchCompletion(
                restoredRoute: restoredRoute, synchronizationResult: synchronizationResult
            )
        }
        return AppContinuityLaunchPreparation(bootstrapState: bootstrapState, completion: completion)
    }

    /// Compatibility for callers that need the complete startup result.
    public func launchIfNeeded(
        canRestoreReaderRoute: Bool,
        onProgress: @escaping @Sendable (AppBootstrapPhase) async -> Void = { _ in }
    ) async -> AppContinuityLaunchResult {
        let prepared = await prepareLaunch(canRestoreReaderRoute: canRestoreReaderRoute, onProgress: onProgress)
        let completion = await prepared.completion.value
        return AppContinuityLaunchResult(bootstrapState: prepared.bootstrapState, restoredRoute: completion.restoredRoute)
    }

    public func prepareReaderRestore() async -> AppContinuityReaderRestorePreparation {
        let (route, routeGeneration) = state.withLock { mutableState in
            (readerResumeRouteStore.loadSync(), mutableState.readerRouteGeneration)
        }
        let accountGeneration = try? await appContext.sessionStore.snapshot().generation
        let progress = await observeReadingProgress(for: route)
        return AppContinuityReaderRestorePreparation(
            route: route, routeGeneration: routeGeneration, accountGeneration: accountGeneration, progress: progress
        )
    }

    public func completeReaderRestore(
        _ startup: AppContinuityReaderRestorePreparation,
        canRestoreReaderRoute: Bool,
        synchronizationResult: WebDAVAutomaticSyncResult
    ) async -> ReaderResumeRoute? {
        guard await isCurrentAccount(for: startup) else { return nil }
        guard canRestoreReaderRoute else {
            // Explicit navigation consumes this window's one startup restore
            // without reading progress or changing its saved route.
            return await restoreReaderRoute(
                canRestoreReaderRoute: false, reconcilesWithReadingProgress: false,
                startup: startup, onProgress: { _ in }
            )
        }
        let after = await observeReadingProgress(for: startup.route)
        let shouldReconcileReadingProgress: Bool
        // A local merge may commit before a failed PUT. Compare the window's
        // own progress even when the overall sync reports skipped after failure.
        if case let .success(previous) = startup.progress,
           case let .success(current?) = after,
           let route = startup.route, current.hasReadingProgress(for: route) {
            shouldReconcileReadingProgress = previous != current
        } else {
            shouldReconcileReadingProgress = synchronizationResult == .downloaded
        }
        return await restoreReaderRoute(
            canRestoreReaderRoute: canRestoreReaderRoute,
            reconcilesWithReadingProgress: shouldReconcileReadingProgress,
            startup: startup,
            onProgress: { _ in }
        )
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
        startup: AppContinuityReaderRestorePreparation?,
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

        var identityResolvedRoute = route
        if case var .manga(context) = route, context.isSmartModeEnabled {
            do {
                let id: MangaDirectoryID?
                if let current = context.directoryID {
                    id = try await appContext.mangaDirectoryStore.canonicalDirectoryID(current)
                } else {
                    id = try await appContext.mangaDirectoryStore.resolveDirectoryID(
                        legacyName: context.directoryName, legacyIdentity: nil, chapterTID: context.chapterTID
                    )
                }
                // Do not destroy an ambiguous old route or guess from a title.
                guard let id else { return nil }
                context.directoryID = id
                context.directoryName = try await appContext.mangaDirectoryStore.identityName(id: id) ?? context.directoryName
                identityResolvedRoute = .manga(context)
            } catch {
                YamiboLog.persistence.warning("Failed to resolve saved manga identity: \(error)")
                return nil
            }
        }

        guard var restoredRoute = await restorableRoute(
            from: identityResolvedRoute,
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

    private func isCurrentRoute(for startup: AppContinuityReaderRestorePreparation?, state: MutableState) -> Bool {
        guard let startup else { return true }
        return state.readerRouteGeneration == startup.routeGeneration
            && readerResumeRouteStore.loadSync() == startup.route
    }

    private func isCurrentAccount(for startup: AppContinuityReaderRestorePreparation?) async -> Bool {
        guard let generation = startup?.accountGeneration else { return true }
        return await appContext.sessionStore.isCurrentGeneration(generation)
    }

    public func foregroundBecameActive() {
        state.withLock {
            $0.isBackgrounded = false
            $0.needsBackgroundFlush = false
        }
        _ = foregroundSynchronization()
    }

    private func foregroundSynchronization() -> Task<WebDAVAutomaticSyncResult, Never> {
        state.withLock { mutableState in
            if let task = mutableState.foregroundSyncTask { return task }
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return WebDAVAutomaticSyncResult.skipped }
                let result = await synchronizeWebDAVSilently()
                state.withLock { current in
                    if current.foregroundSyncID == id {
                        current.foregroundSyncTask = nil
                        current.foregroundSyncID = nil
                    }
                }
                return result
            }
            mutableState.foregroundSyncID = id
            mutableState.foregroundSyncTask = task
            return task
        }
    }

    /// Legacy callers cannot identify their dataset, so retain the conservative
    /// full fingerprint pass. Registered store notifications use the ID overload.
    public func localDataChanged(touchesAppSettings _: Bool = false) {
        state.withLock {
            $0.needsFullLocalFingerprint = true
            $0.hasFreshLocalChangeSignal = true
        }
        scheduleDebouncedUpload()
    }

    func localDataChanged(datasetID: String) {
        state.withLock {
            _ = $0.pendingChangedDatasetIDs.insert(datasetID)
            $0.hasFreshLocalChangeSignal = true
        }
        scheduleDebouncedUpload()
    }

    private struct LocalChangeBatch: Sendable {
        let datasetIDs: Set<String>?
    }

    private func scheduleDebouncedUpload() {
        let previous = state.withLock { mutableState -> Task<Void, Never>? in
            guard !mutableState.isWebDAVSyncInProgress, !mutableState.isBackgrounded,
                  mutableState.hasFreshLocalChangeSignal,
                  mutableState.needsFullLocalFingerprint || !mutableState.pendingChangedDatasetIDs.isEmpty else { return nil }
            let previous = mutableState.debouncedUploadTask
            let id = UUID()
            mutableState.debouncedUploadID = id
            mutableState.debouncedUploadTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                    await self?.synchronizeDebouncedLocalChanges(id: id)
                } catch {
                    // A newer quiet window or background flush owns the changes.
                }
            }
            return previous
        }
        previous?.cancel()
    }

    private func synchronizeDebouncedLocalChanges(id: UUID) async {
        let batch = state.withLock { mutableState -> LocalChangeBatch? in
            guard mutableState.debouncedUploadID == id, !mutableState.isWebDAVSyncInProgress,
                  !mutableState.isBackgrounded, !Task.isCancelled else { return nil }
            mutableState.debouncedUploadTask = nil
            mutableState.debouncedUploadID = nil
            mutableState.isWebDAVSyncInProgress = true
            let batch = LocalChangeBatch(datasetIDs: mutableState.needsFullLocalFingerprint ? nil : mutableState.pendingChangedDatasetIDs)
            mutableState.pendingChangedDatasetIDs.removeAll()
            mutableState.needsFullLocalFingerprint = false
            mutableState.hasFreshLocalChangeSignal = false
            return batch
        }
        guard let batch else { return }
        defer { endWebDAVSync() }
        do {
            _ = try await appContext.makeWebDAVSyncService().synchronizeAutomatically(afterLocalChangesIn: batch.datasetIDs)
        } catch {
            state.withLock {
                if let datasetIDs = batch.datasetIDs {
                    $0.pendingChangedDatasetIDs.formUnion(datasetIDs)
                } else {
                    $0.needsFullLocalFingerprint = true
                }
            }
            // Retain failed candidates for the next change signal or full
            // checkpoint. Requeueing alone must not create a retry timer loop.
            YamiboLog.sync.warning("Debounced local-change WebDAV upload failed: \(error)")
        }
    }

    public func willEnterBackground() {
        state.withLock {
            $0.isBackgrounded = true
            $0.needsBackgroundFlush = true
        }
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

    private func replaceDebouncedUploadTask(with task: Task<Void, Never>?) {
        let previous = state.withLock { mutableState in
            let previous = mutableState.debouncedUploadTask
            mutableState.debouncedUploadTask = task
            mutableState.debouncedUploadID = nil
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
        let needsBackgroundFlush = state.withLock {
            $0.isWebDAVSyncInProgress = false
            return $0.needsBackgroundFlush
        }
        if needsBackgroundFlush {
            Task { [weak self] in await self?.flushWebDAVSyncBeforeBackground() }
        } else {
            // Changes arriving during a read/merge are retained for another
            // quiet window instead of being discarded by the in-flight guard.
            scheduleDebouncedUpload()
        }
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
        let admitted = state.withLock { mutableState in
            guard mutableState.needsBackgroundFlush, !mutableState.isWebDAVSyncInProgress else { return false }
            mutableState.isWebDAVSyncInProgress = true
            mutableState.needsBackgroundFlush = false
            mutableState.pendingChangedDatasetIDs.removeAll()
            mutableState.needsFullLocalFingerprint = false
            mutableState.hasFreshLocalChangeSignal = false
            return true
        }
        guard admitted else { return }
        defer { endWebDAVSync() }

        do {
            // Full marking and reconciliation share the coordinator run, even
            // when backgrounding cancelled the pending debounce before it ran.
            _ = try await appContext.makeWebDAVSyncService().synchronizeAutomatically(
                afterLocalChangesIn: nil, bypassingMinimumInterval: true
            )
        } catch {
            // The next checkpoint or change signal must still inspect all
            // candidates if this full pass failed before marking completed.
            state.withLock { $0.needsFullLocalFingerprint = true }
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
            return try await appContext.readingProgressStore.load(threadID: context.threadID)
        case let .manga(context):
            // Smart Comic Mode off means this thread is treated exactly like a normal
            // thread (smart-comic-mode-design-decisions #2's 总原则): its progress lives
            // ONLY in the precise per-thread `.mangaThread` record. The coincidental
            // `load(threadID:)` OR-match (thread_id = ? OR manga_chapter_thread_id = ?)
            // can otherwise pick up an unrelated directory-level `.mangaTitle` row whose
            // `manga_chapter_thread_id` happens to equal this thread id, silently
            // reconciling the restored route onto a different forum thread.
            if context.isSmartModeEnabled {
                if let directoryID = context.directoryID {
                    return try await appContext.readingProgressStore.load(for: .mangaTitle(
                        mangaID: directoryID.rawValue, cleanBookName: context.directoryName ?? context.displayTitle
                    ))
                }
                return try await appContext.readingProgressStore.load(threadID: context.originalThreadID)
            }
            return try await appContext.readingProgressStore.load(for: .mangaThread(threadID: context.originalThreadID))
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
        let position = NovelReadingResumeResolver.resolve(
            progress: progress.novel, fallbackView: initialView,
            fallbackAuthorID: authorID, fallbackResumePoint: initialResumePoint
        )
        return NovelLaunchContext(
            threadID: threadID,
            threadTitle: favoriteItem?.resolvedDisplayTitle ?? threadTitle,
            source: .resume,
            initialView: position.view,
            authorID: position.authorID,
            initialResumePoint: position.resumePoint,
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
            directoryID: directoryID,
            downloadFavoriteID: favoriteItem?.id ?? downloadFavoriteID,
            isPreview: isPreview,
            isSmartModeEnabled: isSmartModeEnabled,
            forumID: forumID
        )
    }
}
