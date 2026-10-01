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
    private let directoryStore: any MangaDirectoryPersisting
    private var resolvedDirectoryID: MangaDirectoryID?
    private let downloadStore: (any MangaDownloadStoring)?
    private let adjacentPrefetchPolicy: MangaAdjacentChapterPrefetchPolicy
    private var window: MangaChapterWindow?
    // Async work may suspend while another reader action mutates the window.
    // These generations are the workflow's commit boundary: UI-side result
    // guards can prevent a stale publication, but only this owner can prevent
    // a stale task from replacing the window underneath the next action.
    private var sessionGeneration: UInt64 = 0
    private var positionGeneration: UInt64 = 0
    private var navigationMutationGeneration: UInt64 = 0
    private var directoryMutationGeneration: UInt64 = 0
    private var activeDirectoryMutationGeneration: UInt64?
    private var settings: MangaReaderSettings
    private var directoryPanelCommandState = MangaDirectoryPanelCommandState()
    private var preparedDirectoryPanel: PreparedDirectoryPanel?
    private var viewportPlacementRevision = 0
    private var currentViewportPlacement: MangaNovelReaderViewportPlacement?

    private struct NavigationMutationToken: Equatable {
        let sessionGeneration: UInt64
        let positionGeneration: UInt64
        let navigationGeneration: UInt64
    }

    private struct DirectoryMutationToken: Equatable {
        let sessionGeneration: UInt64
        let generation: UInt64
        let directoryID: MangaDirectoryID
    }

    // Directory-derived work is prepared only at directory replacement and
    // sort/chapter boundaries, not on every page turn or cooldown tick.
    private struct PreparedDirectoryPanel {
        var displayChapters: [MangaChapter]
        var sortOrder: MangaDirectorySortOrder
        let latestChapter: MangaChapter?
        var draftChapterTID: String?
        var editDraft: MangaDirectoryEditDraft
    }

    public init(
        context: MangaLaunchContext,
        projectionLoader: any MangaReaderProjectionLoading,
        directoryRepository: any MangaDirectoryRepository,
        directoryStore: any MangaDirectoryPersisting,
        downloadStore: (any MangaDownloadStoring)? = nil,
        settings: MangaReaderSettings = MangaReaderSettings(),
        directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        directorySearchCooldownState: MangaDirectorySearchCooldownState = MangaDirectorySearchCooldownState(),
        adjacentPrefetchPolicy: MangaAdjacentChapterPrefetchPolicy = MangaAdjacentChapterPrefetchPolicy()
    ) {
        self.context = context
        self.projectionLoader = projectionLoader
        self.downloadStore = downloadStore
        self.directoryStore = directoryStore
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
    public nonisolated(nonsending) func prepare(initialProjection: MangaReaderProjection? = nil) async -> MangaReaderPresentation {
        sessionGeneration &+= 1
        positionGeneration &+= 1
        navigationMutationGeneration &+= 1
        directoryMutationGeneration &+= 1
        activeDirectoryMutationGeneration = nil
        let preparationSessionGeneration = sessionGeneration
        window = nil
        preparedDirectoryPanel = nil
        shouldAutoUpdateDirectoryAfterPrepare = false
        directoryPanelCommandState = MangaDirectoryPanelCommandState()
        presentation = MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context))),
            settings: settings
        )

        do {
            if let id = context.directoryID {
                resolvedDirectoryID = try await directoryStore.directory(id: id)?.id ?? id
            } else {
                resolvedDirectoryID = try await directoryStore.resolveDirectoryID(
                    legacyName: context.directoryName ?? context.displayTitle,
                    legacyIdentity: nil, chapterTID: context.chapterTID
                )
            }
            let document: MangaReaderProjection
            if let initialProjection,
               initialProjection.tid == context.chapterTID,
               initialProjection.sourceIdentity.view == context.chapterView,
               !initialProjection.imageURLs.isEmpty {
                document = initialProjection
            } else {
                document = try await projectionLoader.loadReaderProjection(MangaReaderProjectionRequest(
                    threadID: context.chapterTID,
                    view: context.chapterView,
                    offlineOwnerName: resolvedDirectoryID?.rawValue
                ))
            }
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
                    directory: Self.standaloneDirectory(for: document, context: context)
                        .reidentified(as: resolvedDirectoryID ?? MangaDirectoryID(rawValue: "manga-thread:" + document.tid)),
                    shouldAutoUpdateAfterInitialLoad: false
                )
            }
            let directory = resolution.directory
            try await directoryStore.registerIdentity(id: directory.id, name: directory.cleanBookName)
            resolvedDirectoryID = directory.id
            let requestedPosition = MangaReadingPosition(
                tid: document.tid,
                localIndex: context.initialPage
            )
            let window = MangaChapterWindow(
                directory: directory,
                initialDocument: document,
                position: requestedPosition
            )
            guard !Task.isCancelled,
                  sessionGeneration == preparationSessionGeneration else {
                throw CancellationError()
            }
            commitWindow(window, positionChanged: true, directoryChanged: true)
            shouldAutoUpdateDirectoryAfterPrepare = resolution.shouldAutoUpdateAfterInitialLoad
            presentation = loadedPresentation(from: window, placementPageIndex: MangaReaderPageProjection.resolvedPageIndex(for: window))
        } catch {
            guard !Task.isCancelled,
                  !LoadDiagnosticError.isCancellation(error),
                  sessionGeneration == preparationSessionGeneration else { return presentation }
            window = nil
            presentation = MangaReaderPresentation(
                state: .failed(
                    MangaReaderErrorPresentation(
                        title: L10n.string("common.load_failed"),
                        message: error.localizedDescription,
                        details: LoadFailureDetails(error: error)
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
        let title = context.displayTitle.nilIfBlank ?? document.chapterTitle
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
        guard let downloadStore,
              let directoryID = resolvedDirectoryID,
              let membership = await downloadStore.mangaDownloadMembership(ownerName: directoryID.rawValue, tid: document.tid),
              membership.imageURLs.map(\.absoluteString) == document.imageURLs.map(\.absoluteString),
              !membership.imageURLs.isEmpty
        else {
            return nil
        }

        for imageURL in membership.imageURLs {
            // Existence check only — reading the actual bytes of every page
            // just to decide offline readability would load the whole chapter
            // into memory on each reader launch.
            guard await downloadStore.hasOfflineImage(for: imageURL) else {
                return nil
            }
        }

        let title = context.directoryName ?? context.displayTitle
        return MangaDirectory(
            id: directoryID,
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
        commitWindow(window, positionChanged: true)
        currentViewportPlacement = nil
        presentation = loadedPresentation(from: window)
        return presentation
    }

    @discardableResult
    public func jumpToLoadedPage(at globalIndex: Int, animated: Bool = false) -> MangaReaderPresentation {
        guard var window else { return presentation }
        _ = window.moveToLoadedPage(at: globalIndex)
        commitWindow(window, positionChanged: true)
        presentation = loadedPresentation(
            from: window,
            placementPageIndex: MangaReaderPageProjection.resolvedPageIndex(for: window),
            placementAnimated: animated
        )
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func prefetchAdjacentChaptersIfNeeded(around globalIndex: Int) async -> MangaReaderPresentation? {
        guard let window else { return nil }

        let deltas = adjacentPrefetchPolicy.triggeredDeltas(
            globalIndex: globalIndex,
            pageCount: window.pages.count
        )
        guard !deltas.isEmpty else { return nil }

        let session = sessionGeneration
        var documents: [MangaReaderProjection] = []
        for delta in deltas {
            guard !Task.isCancelled else { return nil }
            guard sessionGeneration == session,
                  let windowForLoad = self.window else {
                return nil
            }
            guard let chapter = windowForLoad.adjacentChapterForLoadedRange(delta: delta) else { continue }
            let document: MangaReaderProjection
            do {
                document = try await projectionLoader.loadReaderProjection(
                    MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: windowForLoad.directory.id.rawValue)
                )
            } catch {
                guard !Task.isCancelled else { return nil }
                YamiboLog.reader.warning("Adjacent chapter prefetch failed to load reader projection: \(error)")
                continue
            }
            documents.append(document)
        }

        guard !Task.isCancelled, sessionGeneration == session,
              var rebasedWindow = self.window else { return nil }
        var didChange = false
        for document in documents {
            guard let chapter = rebasedWindow.directory.chapters.first(where: { $0.tid == document.tid }),
                  chapter.view == document.sourceIdentity.view else { continue }
            let result = rebasedWindow.insertAdjacentDocument(
                document,
                preserving: rebasedWindow.resolvedPosition
            )
            if case .changed = result {
                didChange = true
            }
        }

        guard didChange else { return nil }

        commitWindow(rebasedWindow)
        let currentIndex = MangaReaderPageProjection.resolvedPageIndex(for: rebasedWindow)
        presentation = loadedPresentation(from: rebasedWindow, placementPageIndex: currentIndex)
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

        guard let window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let mutation = try beginDirectoryMutation()
        defer { endDirectoryMutationIfNeeded(mutation) }
        let result = try await directoryWorkflow.updateDirectory(
            window.directory,
            currentTID: window.resolvedPosition?.tid,
            isForcedSearch: isForcedSearch
        )
        try Task.checkCancellation()

        _ = try commitDirectoryMutation(result.directory, mutation: mutation)
        return result
    }

    /// Seeds from the currently open chapter (falling back to the
    /// directory's first known chapter, then the launch context's own
    /// chapter) so a reset works even the moment after `prepare()`, before
    /// any reading position has resolved.
    @discardableResult
    public nonisolated(nonsending) func resetDirectory() async throws -> MangaDirectoryUpdateResult {
        try Task.checkCancellation()

        guard let window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let position = window.resolvedPosition
        let seedTID = position?.tid ?? window.directory.chapters.first?.tid ?? context.chapterTID
        let mutation = try beginDirectoryMutation()
        defer { endDirectoryMutationIfNeeded(mutation) }
        let result = try await directoryWorkflow.resetDirectory(window.directory, seedTID: seedTID)
        try Task.checkCancellation()

        _ = try commitDirectoryMutation(result.directory, mutation: mutation)
        return result
    }

    @discardableResult
    public nonisolated(nonsending) func renameDirectory(
        cleanBookName: String,
        searchKeyword: String
    ) async throws -> MangaDirectory {
        try Task.checkCancellation()

        guard let window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let mutation = try beginDirectoryMutation()
        defer { endDirectoryMutationIfNeeded(mutation) }
        let updated = try await directoryWorkflow.renameDirectory(
            window.directory,
            cleanBookName: cleanBookName,
            searchKeyword: searchKeyword
        )
        try Task.checkCancellation()
        _ = try commitDirectoryMutation(updated, mutation: mutation)
        return updated
    }

    @discardableResult
    public nonisolated(nonsending) func deleteDirectoryChapters(tids: Set<String>) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard let window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }

        let targetTIDs = Set(tids.compactMap(Self.normalizedNonEmpty))
        guard !targetTIDs.isEmpty else { return presentation }
        if let currentTID = window.resolvedPosition?.tid,
           targetTIDs.contains(currentTID) {
            return presentation
        }

        let mutation = try beginDirectoryMutation()
        defer { endDirectoryMutationIfNeeded(mutation) }
        let updated = try await directoryWorkflow.deleteChapters(window.directory, tids: targetTIDs)
        try Task.checkCancellation()

        _ = try commitDirectoryMutation(
            updated,
            mutation: mutation,
            removingLoadedTIDs: targetTIDs,
            refreshViewportPlacement: true
        )
        return presentation
    }

    @discardableResult
    public nonisolated(nonsending) func jumpToChapter(_ chapter: MangaChapter) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let navigation = navigationMutationToken()

        let pages = MangaReaderPageProjection.projections(from: window)
        if let loadedIndex = pages.firstIndex(where: { $0.tid == chapter.tid && $0.localIndex == 0 }) {
            _ = window.moveToLoadedPage(at: loadedIndex)
            commitWindow(window, positionChanged: true)
            presentation = loadedPresentation(from: window, placementPageIndex: loadedIndex)
            return presentation
        }

        return try await loadChapterForNavigation(
            chapter,
            localIndex: 0,
            window: window,
            navigation: navigation
        )
    }

    @discardableResult
    public nonisolated(nonsending) func jumpToPosition(_ position: MangaReadingPosition) async throws -> MangaReaderPresentation {
        try Task.checkCancellation()

        guard var window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }
        let navigation = navigationMutationToken()

        let pages = MangaReaderPageProjection.projections(from: window)
        if let loadedPosition = window.clampedPosition(position),
           let loadedIndex = MangaReaderPageProjection.resolvedPageIndex(for: loadedPosition, in: pages) {
            _ = window.moveToLoadedPage(at: loadedIndex)
            commitWindow(window, positionChanged: true)
            presentation = loadedPresentation(from: window, placementPageIndex: loadedIndex)
            return presentation
        }

        guard let chapter = window.directory.chapters.first(where: { $0.tid == position.tid }) else {
            throw YamiboError.underlying("Manga reader target chapter is unavailable.")
        }

        return try await loadChapterForNavigation(
            chapter,
            localIndex: position.localIndex,
            window: window,
            navigation: navigation
        )
    }

    /// Both navigation entry points keep their own target lookup and cached fast
    /// path, but share the loading and publication transaction.
    private nonisolated(nonsending) func loadChapterForNavigation(
        _ chapter: MangaChapter,
        localIndex: Int,
        window initialWindow: MangaChapterWindow,
        navigation: NavigationMutationToken
    ) async throws -> MangaReaderPresentation {
        let document = try await projectionLoader.loadReaderProjection(
            MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: initialWindow.directory.id.rawValue)
        )
        try Task.checkCancellation()
        guard acceptsNavigationMutation(navigation), var window = self.window else {
            throw CancellationError()
        }
        if initialWindow.directory.chapters.contains(where: { $0.tid == chapter.tid }) {
            guard let currentChapter = window.directory.chapters.first(where: { $0.tid == chapter.tid }),
                  currentChapter.view == chapter.view else { throw CancellationError() }
        }

        let targetPosition = MangaReadingPosition(tid: document.tid, localIndex: localIndex)
        let result = window.insertAdjacentDocument(document, preserving: targetPosition)
        switch result {
        case .changed:
            break
        case let .unchanged(_, reason):
            if reason == .duplicateChapter {
                window.updatePosition(targetPosition)
            } else {
                _ = window.reset(to: document, position: targetPosition)
            }
        }

        commitWindow(window, positionChanged: true)
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
        let navigation = navigationMutationToken()

        if let presentation = jumpToLoadedAdjacentChapter(
            chapterTID: chapter.tid,
            delta: delta,
            animated: animated,
            in: initialWindow
        ) {
            return presentation
        }

        let document = try await projectionLoader.loadReaderProjection(
            MangaReaderProjectionRequest(chapter: chapter, offlineOwnerName: initialWindow.directory.id.rawValue)
        )
        try Task.checkCancellation()
        guard !document.imageURLs.isEmpty else {
            throw YamiboError.unreadableBody
        }

        guard acceptsNavigationMutation(navigation),
              var currentWindow = window,
              currentWindow.resolvedPosition == sourcePosition,
              let currentChapter = currentWindow.adjacentChapter(from: sourcePosition, delta: delta),
              currentChapter.tid == chapter.tid,
              currentChapter.view == chapter.view else {
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

        commitWindow(currentWindow, positionChanged: true)
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

    public func currentDirectoryID() -> MangaDirectoryID? { window?.directory.id }

    /// Other windows can rename or merge this identity while a chapter is open.
    /// Resolve the latest metadata without discarding the loaded image pages.
    public nonisolated(nonsending) func refreshPersistedDirectory() async throws -> MangaReaderPresentation? {
        guard context.isSmartModeEnabled,
              let mutation = directoryObservationToken() else { return nil }
        let latest = try await directoryStore.directory(id: mutation.directoryID)
        try Task.checkCancellation()
        guard let latest,
              acceptsDirectoryObservation(mutation),
              var current = window,
              current.directory.id == mutation.directoryID,
              current.directory != latest else { return nil }
        _ = current.updateDirectory(latest, preserving: current.resolvedPosition)
        commitWindow(current, directoryChanged: true)
        finishDirectoryObservation(mutation)
        presentation = loadedPresentation(from: current)
        return presentation
    }

    public func currentHistoryDirectory() -> MangaDirectory? {
        context.isSmartModeEnabled ? window?.directory : nil
    }

    public func currentDirectoryCleanBookName() -> String? {
        window?.directory.cleanBookName
    }

    private func navigationMutationToken() -> NavigationMutationToken {
        navigationMutationGeneration &+= 1
        return NavigationMutationToken(
            sessionGeneration: sessionGeneration,
            positionGeneration: positionGeneration,
            navigationGeneration: navigationMutationGeneration
        )
    }

    private func acceptsNavigationMutation(_ token: NavigationMutationToken) -> Bool {
        !Task.isCancelled
            && token.sessionGeneration == sessionGeneration
            && token.positionGeneration == positionGeneration
            && token.navigationGeneration == navigationMutationGeneration
            && window != nil
    }

    private func beginDirectoryMutation() throws -> DirectoryMutationToken {
        try Task.checkCancellation()
        guard let window else {
            throw YamiboError.underlying("Manga reader workflow is not prepared.")
        }

        directoryMutationGeneration &+= 1
        activeDirectoryMutationGeneration = directoryMutationGeneration
        return DirectoryMutationToken(
            sessionGeneration: sessionGeneration,
            generation: directoryMutationGeneration,
            directoryID: window.directory.id
        )
    }

    private func endDirectoryMutationIfNeeded(_ token: DirectoryMutationToken) {
        guard activeDirectoryMutationGeneration == token.generation else { return }
        activeDirectoryMutationGeneration = nil
    }

    private func directoryObservationToken() -> DirectoryMutationToken? {
        guard let window, activeDirectoryMutationGeneration == nil else { return nil }
        return DirectoryMutationToken(
            sessionGeneration: sessionGeneration,
            generation: directoryMutationGeneration,
            directoryID: window.directory.id
        )
    }

    private func acceptsDirectoryMutation(_ token: DirectoryMutationToken) -> Bool {
        !Task.isCancelled
            && activeDirectoryMutationGeneration == token.generation
            && token.sessionGeneration == sessionGeneration
            && token.generation == directoryMutationGeneration
            && window?.directory.id == token.directoryID
    }

    private func acceptsDirectoryObservation(_ token: DirectoryMutationToken) -> Bool {
        !Task.isCancelled
            && activeDirectoryMutationGeneration == nil
            && token.sessionGeneration == sessionGeneration
            && token.generation == directoryMutationGeneration
            && window?.directory.id == token.directoryID
    }

    private func finishDirectoryObservation(_ token: DirectoryMutationToken) {
        guard token.generation == directoryMutationGeneration,
              activeDirectoryMutationGeneration == nil else { return }
        directoryMutationGeneration &+= 1
    }

    private func commitDirectoryMutation(
        _ directory: MangaDirectory,
        mutation: DirectoryMutationToken,
        removingLoadedTIDs: Set<String>? = nil,
        refreshViewportPlacement: Bool = false
    ) throws -> MangaReaderPresentation {
        guard acceptsDirectoryMutation(mutation), var current = window else {
            throw CancellationError()
        }

        let position = current.resolvedPosition
        _ = current.updateDirectory(directory, preserving: position)
        if let removingLoadedTIDs {
            _ = current.removeLoadedDocuments(
                withTIDs: removingLoadedTIDs,
                preserving: position
            )
        }

        // Rebase the directory result onto the latest window rather than the
        // snapshot that was captured before the external store/network work.
        // This preserves a page turn or chapter load that completed while the
        // directory command was suspended.
        commitWindow(current, directoryChanged: true)
        activeDirectoryMutationGeneration = nil
        directoryMutationGeneration &+= 1

        let placementPageIndex = refreshViewportPlacement
            ? MangaReaderPageProjection.resolvedPageIndex(for: current)
            : nil
        presentation = loadedPresentation(from: current, placementPageIndex: placementPageIndex)
        return presentation
    }

    private func commitWindow(
        _ nextWindow: MangaChapterWindow,
        positionChanged: Bool = false,
        directoryChanged: Bool = false
    ) {
        window = nextWindow
        if directoryChanged {
            preparedDirectoryPanel = nil
        }
        if positionChanged {
            positionGeneration &+= 1
        }
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
                    directoryID: window.directory.id,
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
        commitWindow(updatedWindow, positionChanged: true)
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
        let currentChapterTID = window.resolvedPosition?.tid
        if preparedDirectoryPanel == nil {
            preparedDirectoryPanel = PreparedDirectoryPanel(
                displayChapters: window.directory.chapters,
                sortOrder: .ascending,
                latestChapter: MangaChapterDisplayFormatter.latestChapter(in: window.directory.chapters),
                draftChapterTID: currentChapterTID,
                editDraft: directoryWorkflow.editDraft(for: window.directory, currentTID: currentChapterTID)
            )
        }
        if preparedDirectoryPanel?.sortOrder != settings.directorySortOrder {
            preparedDirectoryPanel?.displayChapters = switch settings.directorySortOrder {
            case .ascending:
                window.directory.chapters
            case .descending:
                Array(window.directory.chapters.reversed())
            }
            preparedDirectoryPanel?.sortOrder = settings.directorySortOrder
        }
        if preparedDirectoryPanel?.draftChapterTID != currentChapterTID {
            preparedDirectoryPanel?.editDraft = directoryWorkflow.editDraft(
                for: window.directory,
                currentTID: currentChapterTID
            )
            preparedDirectoryPanel?.draftChapterTID = currentChapterTID
        }
        let latestChapterText = preparedDirectoryPanel?.latestChapter.map {
            L10n.string("manga.latest_chapter", MangaChapterDisplayFormatter.displayNumber(for: $0))
        }
        return MangaDirectoryPanelPresentation(
            directoryTitle: window.directory.cleanBookName,
            directoryID: window.directory.id,
            displayChapters: preparedDirectoryPanel?.displayChapters ?? [],
            currentChapterTID: currentChapterTID,
            latestChapterText: latestChapterText,
            sortOrder: settings.directorySortOrder,
            updateButtonTitle: directoryPanelCommandState.updateButtonTitle(strategy: window.directory.strategy),
            isUpdateButtonEnabled: directoryPanelCommandState.isUpdateButtonEnabled,
            isSearchMode: directoryPanelCommandState.isSearchMode(strategy: window.directory.strategy),
            shouldForceSearchOnUpdate: directoryPanelCommandState.shouldForceSearchOnUpdate,
            isUpdating: directoryPanelCommandState.isUpdating,
            editDraft: preparedDirectoryPanel?.editDraft,
            errorMessage: directoryPanelCommandState.errorMessage,
            errorDetails: directoryPanelCommandState.errorDetails,
            failureEventID: directoryPanelCommandState.failureEventID
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
            previousSettings.pageEdgeFillStyle != settings.pageEdgeFillStyle
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
