import Foundation

public struct MangaAdjacentChapterPrefetchPolicy: Hashable, Sendable {
    public var nextTriggerDistanceFromEnd: Int
    public var previousTriggerMaximumIndex: Int

    public init(
        nextTriggerDistanceFromEnd: Int = 6,
        previousTriggerMaximumIndex: Int = 2
    ) {
        self.nextTriggerDistanceFromEnd = max(0, nextTriggerDistanceFromEnd)
        self.previousTriggerMaximumIndex = max(0, previousTriggerMaximumIndex)
    }

    public func triggeredDeltas(globalIndex: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }

        let normalizedIndex = min(max(globalIndex, 0), pageCount - 1)
        var deltas: [Int] = []
        if normalizedIndex >= pageCount - nextTriggerDistanceFromEnd {
            deltas.append(1)
        }
        if normalizedIndex <= previousTriggerMaximumIndex {
            deltas.append(-1)
        }
        return deltas
    }
}

/// Caller-isolated (non-`Sendable`): the workflow runs entirely in whatever
/// isolation domain owns it, so its synchronous page-turn API stays synchronous
/// and its `async` methods (`nonisolated(nonsending)`) never hop executors.
public final class MangaReaderWorkflow {
    public private(set) var presentation: MangaReaderPresentation
    public private(set) var shouldAutoUpdateDirectoryAfterPrepare = false

    private let context: MangaLaunchContext
    private let projectionLoader: any MangaReaderProjectionLoading
    private let directoryWorkflow: MangaDirectoryWorkflow
    private let offlineCacheStore: (any MangaOfflineCacheStoring)?
    private let adjacentPrefetchPolicy: MangaAdjacentChapterPrefetchPolicy
    private var window: MangaChapterWindow?
    private var settings: MangaReaderSettings
    private var directoryPanelCommandState = MangaDirectoryPanelCommandState()
    private var viewportPlacementRevision = 0
    private var currentViewportPlacement: MangaNovelReaderViewportPlacement?

    public init(
        context: MangaLaunchContext,
        projectionLoader: any MangaReaderProjectionLoading,
        directoryRepository: any MangaDirectoryRepository,
        directoryStore: any MangaDirectoryPersisting,
        offlineCacheStore: (any MangaOfflineCacheStoring)? = nil,
        settings: MangaReaderSettings = MangaReaderSettings(),
        directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        directorySearchCooldownState: MangaDirectorySearchCooldownState = MangaDirectorySearchCooldownState(),
        adjacentPrefetchPolicy: MangaAdjacentChapterPrefetchPolicy = MangaAdjacentChapterPrefetchPolicy()
    ) {
        self.context = context
        self.projectionLoader = projectionLoader
        self.offlineCacheStore = offlineCacheStore
        self.adjacentPrefetchPolicy = adjacentPrefetchPolicy
        self.directoryWorkflow = MangaDirectoryWorkflow(
            repository: directoryRepository,
            store: directoryStore,
            configuration: directoryWorkflowConfiguration,
            searchCooldownState: directorySearchCooldownState
        )
        self.settings = settings
        self.presentation = MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context))),
            settings: settings
        )
    }

    @discardableResult
    public nonisolated(nonsending) func prepare() async -> MangaReaderPresentation {
        window = nil
        shouldAutoUpdateDirectoryAfterPrepare = false
        directoryPanelCommandState = MangaDirectoryPanelCommandState()
        presentation = MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context))),
            settings: settings
        )

        do {
            let document = try await projectionLoader.loadReaderProjection(
                MangaReaderProjectionRequest(
                    threadID: context.chapterTID,
                    view: context.chapterView,
                    offlineOwnerName: context.directoryName
                )
            )
            let resolution: MangaDirectoryResolutionResult
            if context.isSmartModeEnabled {
                do {
                    resolution = try await directoryWorkflow.resolveInitialDirectory(
                        context: context,
                        projection: document
                    )
                } catch {
                    guard let offlineDirectory = await offlineReadableCurrentChapterDirectory(for: document) else {
                        throw error
                    }
                    YamiboLog.reader.warning("Initial directory resolution failed, falling back to offline-readable directory: \(error)")
                    resolution = MangaDirectoryResolutionResult(
                        directory: offlineDirectory,
                        shouldAutoUpdateAfterInitialLoad: false
                    )
                }
            } else {
                // Smart Comic Mode is off for this thread's board: per
                // decision #12, skip `resolveInitialDirectory` entirely (no
                // directory-related network activity at all), not just
                // "resolve but ignore the result". Synthesize a single-
                // chapter pseudo-directory containing only this chapter —
                // this thread is read exactly like a normal thread, with no
                // siblings and no auto-update, matching the "totally
                // standalone" reading behavior mode-off documents.
                resolution = MangaDirectoryResolutionResult(
                    directory: Self.standaloneDirectory(for: document, context: context),
                    shouldAutoUpdateAfterInitialLoad: false
                )
            }
            let directory = resolution.directory
            let requestedPosition = MangaReadingPosition(
                tid: document.tid,
                localIndex: context.initialPage
            )
            let window = MangaChapterWindow(
                directory: directory,
                initialDocument: document,
                position: requestedPosition
            )
            self.window = window
            shouldAutoUpdateDirectoryAfterPrepare = resolution.shouldAutoUpdateAfterInitialLoad
            presentation = loadedPresentation(from: window, placementPageIndex: MangaReaderPageProjection.resolvedPageIndex(for: window))
        } catch {
            window = nil
            presentation = MangaReaderPresentation(
                state: .failed(
                    MangaReaderErrorPresentation(
                        title: L10n.string("common.load_failed"),
                        message: error.localizedDescription
                    )
                ),
                settings: settings
            )
        }

        return presentation
    }

    /// A single-chapter, never-persisted `MangaDirectory` used when Smart
    /// Comic Mode is off for this chapter's board (decision #12). It exists
    /// only to satisfy `MangaChapterWindow`'s non-optional `directory`
    /// parameter with the least disruption to its existing shape — see the
    /// Phase B report for why this was chosen over making `directory`
    /// optional. Because it contains no sibling chapters,
    /// `adjacentChapter`/`adjacentChapterForLoadedRange` naturally return
    /// `nil`, so chapter-jump affordances are unavailable without any extra
    /// gating. `strategy` is never read for anything persisted here — this
    /// directory is never passed to `directoryStore.saveDirectory` — so
    /// `.pendingSearch` is chosen only to mirror the existing single-chapter
    /// offline fallback below.
    private static func standaloneDirectory(
        for document: MangaReaderProjection,
        context: MangaLaunchContext
    ) -> MangaDirectory {
        let title = context.displayTitle.mangaReaderTrimmedNonEmpty ?? document.chapterTitle
        return MangaDirectory(
            cleanBookName: title,
            strategy: .pendingSearch,
            sourceKey: title,
            chapters: [
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
    }

    private nonisolated(nonsending) func offlineReadableCurrentChapterDirectory(for document: MangaReaderProjection) async -> MangaDirectory? {
        guard let offlineCacheStore,
              let ownerName = context.directoryName?.mangaReaderTrimmedNonEmpty,
              let membership = await offlineCacheStore.mangaOfflineCacheMembership(ownerName: ownerName, tid: document.tid),
              membership.imageURLs.map(\.absoluteString) == document.imageURLs.map(\.absoluteString),
              !membership.imageURLs.isEmpty
        else {
            return nil
        }

        for imageURL in membership.imageURLs {
            // Existence check only — reading the actual bytes of every page
            // just to decide offline readability would load the whole chapter
            // into memory on each reader launch.
            guard await offlineCacheStore.hasOfflineImage(for: imageURL) else {
                return nil
            }
        }

        let title = ownerName
        return MangaDirectory(
            cleanBookName: title,
            strategy: .pendingSearch,
            sourceKey: title,
            chapters: [
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
    }

    @discardableResult
    public func moveToLoadedPage(at globalIndex: Int) -> MangaReaderPresentation {
        guard var window else { return presentation }
        _ = window.moveToLoadedPage(at: globalIndex)
        self.window = window
        currentViewportPlacement = nil
        presentation = loadedPresentation(from: window)
        return presentation
    }

    @discardableResult
    public func jumpToLoadedPage(at globalIndex: Int, animated: Bool = false) -> MangaReaderPresentation {
        guard var window else { return presentation }
        _ = window.moveToLoadedPage(at: globalIndex)
        self.window = window
        presentation = loadedPresentation(
            from: window,
            placementPageIndex: MangaReaderPageProjection.resolvedPageIndex(for: window),
            placementAnimated: animated
        )
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func prefetchAdjacentChaptersIfNeeded(around globalIndex: Int) async -> MangaReaderPresentation? {
        guard var window else { return nil }

        let pages = MangaReaderPageProjection.projections(from: window)
        let deltas = adjacentPrefetchPolicy.triggeredDeltas(
            globalIndex: globalIndex,
            pageCount: pages.count
        )
        guard !deltas.isEmpty else { return nil }

        let preservedPosition = window.resolvedPosition
        var didChange = false
        for delta in deltas {
            guard !Task.isCancelled else { return nil }
            guard let chapter = window.adjacentChapterForLoadedRange(delta: delta) else { continue }
            let document: MangaReaderProjection
            do {
                document = try await projectionLoader.loadReaderProjection(
                    MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: window.directory.cleanBookName)
                )
            } catch {
                guard !Task.isCancelled else { return nil }
                YamiboLog.reader.warning("Adjacent chapter prefetch failed to load reader projection: \(error)")
                continue
            }
            guard !Task.isCancelled else { return nil }

            let result = window.insertAdjacentDocument(document, preserving: preservedPosition)
            if case .changed = result {
                didChange = true
            }
        }

        guard didChange else { return nil }

        self.window = window
        let currentIndex = MangaReaderPageProjection.resolvedPageIndex(for: window)
        presentation = loadedPresentation(from: window, placementPageIndex: currentIndex)
        return presentation
    }

    @discardableResult
    public func applySettings(_ settings: MangaReaderSettings) -> MangaReaderPresentation {
        let previousSettings = self.settings
        self.settings = settings
        if let window {
            let placementPageIndex = Self.requiresViewportPlacementRefresh(
                from: previousSettings,
                to: settings
            ) ? MangaReaderPageProjection.resolvedPageIndex(for: window) : nil
            presentation = loadedPresentation(from: window, placementPageIndex: placementPageIndex)
        } else {
            presentation.settings = settings
        }
        return presentation
    }

    @discardableResult
    public func updateDirectoryPanelCommandState(
        _ state: MangaDirectoryPanelCommandState
    ) -> MangaReaderPresentation {
        directoryPanelCommandState = state
        if let window {
            presentation = loadedPresentation(from: window)
        }
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func updateDirectory(isForcedSearch: Bool = false) async throws -> MangaDirectoryUpdateResult {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let result = try await directoryWorkflow.updateDirectory(
            window.directory,
            currentTID: window.resolvedPosition?.tid,
            isForcedSearch: isForcedSearch
        )
        try Task.checkCancellation()

        let position = window.resolvedPosition
        _ = window.updateDirectory(result.directory, preserving: position)
        self.window = window
        presentation = loadedPresentation(from: window)
        return result
    }

    /// Seeds from the currently open chapter (falling back to the
    /// directory's first known chapter, then the launch context's own
    /// chapter) so a reset works even the moment after `prepare()`, before
    /// any reading position has resolved.
    @discardableResult
    public nonisolated(nonsending) func resetDirectory() async throws -> MangaDirectoryUpdateResult {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let position = window.resolvedPosition
        let seedTID = position?.tid ?? window.directory.chapters.first?.tid ?? context.chapterTID
        let result = try await directoryWorkflow.resetDirectory(window.directory, seedTID: seedTID)
        try Task.checkCancellation()

        _ = window.updateDirectory(result.directory, preserving: position)
        self.window = window
        presentation = loadedPresentation(from: window)
        return result
    }

    @discardableResult
    public nonisolated(nonsending) func renameDirectory(
        cleanBookName: String,
        searchKeyword: String
    ) async throws -> MangaDirectory {
        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let updated = try await directoryWorkflow.renameDirectory(
            window.directory,
            cleanBookName: cleanBookName,
            searchKeyword: searchKeyword
        )
        let position = window.resolvedPosition
        _ = window.updateDirectory(updated, preserving: position)
        self.window = window
        presentation = loadedPresentation(from: window)
        return updated
    }

    @discardableResult
    public nonisolated(nonsending) func deleteDirectoryChapters(tids: Set<String>) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }

        let targetTIDs = Set(tids.compactMap(Self.normalizedNonEmpty))
        guard !targetTIDs.isEmpty else { return presentation }
        if let currentTID = window.resolvedPosition?.tid,
           targetTIDs.contains(currentTID) {
            return presentation
        }

        let position = window.resolvedPosition
        let updated = try await directoryWorkflow.deleteChapters(window.directory, tids: targetTIDs)
        try Task.checkCancellation()

        _ = window.updateDirectory(updated, preserving: position)
        _ = window.removeLoadedDocuments(withTIDs: targetTIDs, preserving: position)
        self.window = window
        let currentIndex = MangaReaderPageProjection.resolvedPageIndex(for: window)
        presentation = loadedPresentation(from: window, placementPageIndex: currentIndex)
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func jumpToChapter(_ chapter: MangaChapter) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }

        let pages = MangaReaderPageProjection.projections(from: window)
        if let loadedIndex = pages.firstIndex(where: { $0.tid == chapter.tid && $0.localIndex == 0 }) {
            _ = window.moveToLoadedPage(at: loadedIndex)
            self.window = window
            presentation = loadedPresentation(from: window, placementPageIndex: loadedIndex)
            return presentation
        }

        let document = try await projectionLoader.loadReaderProjection(
            MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: window.directory.cleanBookName)
        )
        try Task.checkCancellation()

        let targetPosition = MangaReadingPosition(tid: document.tid, localIndex: 0)
        let result = window.insertAdjacentDocument(document, preserving: targetPosition)
        switch result {
        case .changed:
            break
        case let .unchanged(_, reason):
            if reason != .duplicateChapter {
                _ = window.reset(to: document, position: targetPosition)
            }
        }

        self.window = window
        let targetIndex = MangaReaderPageProjection.resolvedPageIndex(for: window)
        presentation = loadedPresentation(from: window, placementPageIndex: targetIndex)
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func jumpToPosition(_ position: MangaReadingPosition) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }

        let pages = MangaReaderPageProjection.projections(from: window)
        if let loadedPosition = window.clampedPosition(position),
           let loadedIndex = MangaReaderPageProjection.resolvedPageIndex(for: loadedPosition, in: pages) {
            _ = window.moveToLoadedPage(at: loadedIndex)
            self.window = window
            presentation = loadedPresentation(from: window, placementPageIndex: loadedIndex)
            return presentation
        }

        guard let chapter = window.directory.chapters.first(where: { $0.tid == position.tid }) else {
            throw YamiboError.underlying("Manga reader target chapter is unavailable.")
        }

        let document = try await projectionLoader.loadReaderProjection(
            MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: window.directory.cleanBookName)
        )
        try Task.checkCancellation()

        let targetPosition = MangaReadingPosition(tid: document.tid, localIndex: position.localIndex)
        let result = window.insertAdjacentDocument(document, preserving: targetPosition)
        switch result {
        case .changed:
            break
        case let .unchanged(_, reason):
            if reason != .duplicateChapter {
                _ = window.reset(to: document, position: targetPosition)
            }
        }

        self.window = window
        let targetIndex = MangaReaderPageProjection.resolvedPageIndex(for: window)
        presentation = loadedPresentation(from: window, placementPageIndex: targetIndex)
        return presentation
    }

    public func canJumpToAdjacentChapter(
        from position: MangaReadingPosition?,
        delta: Int
    ) -> Bool {
        guard abs(delta) == 1,
              let window,
              let position = window.clampedPosition(position) else {
            return false
        }
        return window.adjacentChapter(from: position, delta: delta) != nil
    }

    @discardableResult
    public nonisolated(nonsending) func jumpToAdjacentChapter(
        from position: MangaReadingPosition?,
        delta: Int,
        animated: Bool = false
    ) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard abs(delta) == 1,
              let initialWindow = window,
              let sourcePosition = initialWindow.clampedPosition(position),
              let chapter = initialWindow.adjacentChapter(from: sourcePosition, delta: delta) else {
            throw YamiboError.underlying("Manga reader adjacent chapter is unavailable.")
        }

        if let presentation = jumpToLoadedAdjacentChapter(
            chapterTID: chapter.tid,
            delta: delta,
            animated: animated,
            in: initialWindow
        ) {
            return presentation
        }

        let document = try await projectionLoader.loadReaderProjection(
            MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: initialWindow.directory.cleanBookName)
        )
        try Task.checkCancellation()
        guard !document.imageURLs.isEmpty else {
            throw YamiboError.unreadableBody
        }

        guard var currentWindow = window,
              currentWindow.resolvedPosition == sourcePosition else {
            throw CancellationError()
        }

        if let presentation = jumpToLoadedAdjacentChapter(
            chapterTID: chapter.tid,
            delta: delta,
            animated: animated,
            in: currentWindow
        ) {
            return presentation
        }

        let targetPosition = Self.adjacentChapterTargetPosition(document: document, delta: delta)
        let result = currentWindow.insertAdjacentDocument(document, preserving: targetPosition)
        guard case .changed = result,
              let targetIndex = MangaReaderPageProjection.resolvedPageIndex(for: currentWindow) else {
            throw YamiboError.underlying("Manga reader adjacent chapter could not be inserted.")
        }

        self.window = currentWindow
        presentation = loadedPresentation(
            from: currentWindow,
            placementPageIndex: targetIndex,
            placementAnimated: animated
        )
        return presentation
    }

    public nonisolated(nonsending) func currentDirectorySearchCooldownExpiresAt() async -> Date? {
        await directoryWorkflow.cooldownExpiresAt()
    }

    public func currentDirectoryFavoriteIdentity() -> String? {
        window?.directory.favoriteIdentity
    }

    public func currentDirectoryCleanBookName() -> String? {
        window?.directory.cleanBookName
    }

    private func loadedPresentation(
        from window: MangaChapterWindow,
        placementPageIndex: Int? = nil,
        placementAnimated: Bool = false
    ) -> MangaReaderPresentation {
        let pages = MangaReaderPageProjection.projections(from: window)
        let currentPageIndex = MangaReaderPageProjection.resolvedPageIndex(for: window)
        let currentPage = currentPageIndex.flatMap { index in
            pages.indices.contains(index) ? pages[index] : nil
        }
        let viewportPlacement = placementPageIndex.map { index in
            nextViewportPlacement(targetPageIndex: index, animated: placementAnimated)
        } ?? currentViewportPlacement

        return MangaReaderPresentation(
            state: .loaded(
                MangaReaderLoadedPresentation(
                    title: Self.presentationTitle(for: context),
                    directoryTitle: window.directory.cleanBookName,
                    pages: pages,
                    currentPage: currentPage,
                    currentPageIndex: currentPageIndex,
                    readingPosition: window.resolvedPosition,
                    directoryPanel: directoryPanelPresentation(from: window),
                    viewportPlacement: viewportPlacement
                )
            ),
            settings: settings
        )
    }

    private func jumpToLoadedAdjacentChapter(
        chapterTID: String,
        delta: Int,
        animated: Bool,
        in window: MangaChapterWindow
    ) -> MangaReaderPresentation? {
        let pages = MangaReaderPageProjection.projections(from: window)
        let loadedIndex: Int?
        if delta < 0 {
            loadedIndex = pages.lastIndex(where: { page in
                page.tid == chapterTID
            })
        } else {
            loadedIndex = pages.firstIndex(where: { page in
                page.tid == chapterTID
            })
        }
        guard let loadedIndex else { return nil }

        var updatedWindow = window
        _ = updatedWindow.moveToLoadedPage(at: loadedIndex)
        self.window = updatedWindow
        presentation = loadedPresentation(
            from: updatedWindow,
            placementPageIndex: loadedIndex,
            placementAnimated: animated
        )
        return presentation
    }

    private static func adjacentChapterTargetPosition(
        document: MangaReaderProjection,
        delta: Int
    ) -> MangaReadingPosition {
        MangaReadingPosition(
            tid: document.tid,
            localIndex: delta < 0 ? document.imageURLs.count - 1 : 0
        )
    }

    private func directoryPanelPresentation(from window: MangaChapterWindow) -> MangaDirectoryPanelPresentation {
        let displayChapters: [MangaChapter] = switch settings.directorySortOrder {
        case .ascending:
            window.directory.chapters
        case .descending:
            Array(window.directory.chapters.reversed())
        }
        let latestChapterText = MangaChapterDisplayFormatter.latestChapter(in: window.directory.chapters).map {
            L10n.string("manga.latest_chapter", MangaChapterDisplayFormatter.displayNumber(for: $0))
        }
        let forcedRemaining = directoryPanelCommandState.forcedSearchShortcutRemaining
        let isSearchMode = forcedRemaining != nil || window.directory.strategy != .tag
        let updateTitle: String
        if directoryPanelCommandState.isUpdating {
            updateTitle = L10n.string("common.updating")
        } else if directoryPanelCommandState.cooldownRemaining > 0 {
            updateTitle = "\(directoryPanelCommandState.cooldownRemaining)s"
        } else if let forcedRemaining {
            updateTitle = forcedRemaining > 0
                ? L10n.string("manga.global_search_countdown", forcedRemaining)
                : L10n.string("manga.global_search")
        } else if window.directory.strategy != .tag {
            updateTitle = L10n.string("manga.global_search")
        } else {
            updateTitle = L10n.string("reader.cache_action.update")
        }

        return MangaDirectoryPanelPresentation(
            directoryTitle: window.directory.cleanBookName,
            displayChapters: displayChapters,
            currentChapterTID: window.resolvedPosition?.tid,
            latestChapterText: latestChapterText,
            sortOrder: settings.directorySortOrder,
            updateButtonTitle: updateTitle,
            isUpdateButtonEnabled: !directoryPanelCommandState.isUpdating && directoryPanelCommandState.cooldownRemaining <= 0,
            isSearchMode: isSearchMode,
            shouldForceSearchOnUpdate: forcedRemaining != nil,
            isUpdating: directoryPanelCommandState.isUpdating,
            editDraft: directoryWorkflow.editDraft(for: window.directory, currentTID: window.resolvedPosition?.tid),
            errorMessage: directoryPanelCommandState.errorMessage
        )
    }

    private func nextViewportPlacement(targetPageIndex: Int, animated: Bool = false) -> MangaNovelReaderViewportPlacement {
        viewportPlacementRevision += 1
        let placement = MangaNovelReaderViewportPlacement(
            targetPageIndex: targetPageIndex,
            animated: animated,
            revision: viewportPlacementRevision
        )
        currentViewportPlacement = placement
        return placement
    }

    private static func requiresViewportPlacementRefresh(
        from previousSettings: MangaReaderSettings,
        to settings: MangaReaderSettings
    ) -> Bool {
        previousSettings.readingMode != settings.readingMode ||
            previousSettings.pagedTurnStyle != settings.pagedTurnStyle ||
            previousSettings.pageTurnDirection != settings.pageTurnDirection ||
            previousSettings.pageScaleMode != settings.pageScaleMode ||
            previousSettings.pageEdgeFillStyle != settings.pageEdgeFillStyle ||
            previousSettings.showsTwoPagesInLandscapeOnPad != settings.showsTwoPagesInLandscapeOnPad
    }

    private static func presentationTitle(for context: MangaLaunchContext) -> String {
        let title = context.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.string("manga.reader.title") : title
    }

    private static func normalizedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
