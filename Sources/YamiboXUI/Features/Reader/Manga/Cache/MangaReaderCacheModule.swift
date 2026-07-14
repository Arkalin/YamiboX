import Combine
import Foundation
import YamiboXCore

public struct MangaReaderCacheRow: Hashable, Identifiable, Sendable {
    public var chapter: MangaChapter
    public var state: MangaOfflineCacheState

    public var id: String { chapter.tid }

    public init(chapter: MangaChapter, state: MangaOfflineCacheState) {
        self.chapter = chapter
        self.state = state
    }
}

public enum MangaReaderCachePrompt: Equatable, Identifiable, Sendable {
    case addFavorite(title: String)

    public var id: String {
        switch self {
        case .addFavorite:
            "addFavorite"
        }
    }
}

@MainActor
public final class MangaReaderCacheViewModel: ObservableObject {
    @Published public private(set) var rows: [MangaReaderCacheRow] = []
    @Published public private(set) var favorite: Favorite?
    @Published public private(set) var prompt: MangaReaderCachePrompt?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var offlineCacheQueueEntryCount = 0

    private let context: MangaLaunchContext
    private let panel: MangaDirectoryPanelPresentation
    private let localFavoriteLibraryStore: FavoriteLibraryStore
    private let offlineCacheStore: any MangaOfflineCacheStoring & OfflineCacheQueueStoring
    private let offlineCacheQueueControllerProvider: (@Sendable () async -> any OfflineCacheQueueControlling)?
    private var offlineCacheQueueController: (any OfflineCacheQueueControlling)?
    private var offlineCacheUpdatesTask: Task<Void, Never>?

    public init(
        context: MangaLaunchContext,
        panel: MangaDirectoryPanelPresentation,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        offlineCacheStore: any MangaOfflineCacheStoring & OfflineCacheQueueStoring,
        offlineCacheQueueControllerProvider: (@Sendable () async -> any OfflineCacheQueueControlling)? = nil
    ) {
        self.context = context
        self.panel = panel
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.offlineCacheStore = offlineCacheStore
        self.offlineCacheQueueControllerProvider = offlineCacheQueueControllerProvider
    }

    deinit {
        offlineCacheUpdatesTask?.cancel()
    }

    public var allChapterTIDs: Set<String> {
        Set(rows.map(\.chapter.tid))
    }

    public func load() async {
        startObservingOfflineCacheUpdates()
        favorite = await localFavoriteItem()?.favorite(type: .manga)
        await refreshRows()
    }

    public func refreshRows() async {
        await refreshChapterRows()
        await refreshOfflineCacheQueueEntryCount()
    }

    private func refreshChapterRows() async {
        let ownerName = offlineCacheOwnerName
        var nextRows: [MangaReaderCacheRow] = []
        for chapter in panel.displayChapters {
            let state: MangaOfflineCacheState
            if let ownerName {
                state = await offlineCacheStore.mangaOfflineCacheState(ownerName: ownerName, tid: chapter.tid)
            } else {
                state = .uncached
            }
            nextRows.append(MangaReaderCacheRow(chapter: chapter, state: state))
        }
        rows = nextRows
    }

    private func refreshOfflineCacheQueueEntryCount() async {
        offlineCacheQueueEntryCount = await mangaQueueWorks().count
    }

    public func selectionState(for selectedTIDs: Set<String>) -> ReaderCacheSelectionState {
        let validSelection = selectedTIDs.intersection(allChapterTIDs)
        let stateByTID = Dictionary(uniqueKeysWithValues: rows.map { ($0.chapter.tid, $0.state) })
        let uncached = validSelection.filter { stateByTID[$0] == .uncached }
        let removable = validSelection.filter { tid in
            switch stateByTID[tid] {
            case .cached, .caching:
                true
            case .uncached, nil:
                false
            }
        }
        return ReaderCacheSelectionState(
            selectedTIDs: validSelection,
            uncachedSelectedTIDs: Set(uncached),
            removableSelectedTIDs: Set(removable),
            canCache: !uncached.isEmpty,
            canDelete: !removable.isEmpty,
            isAllSelected: !rows.isEmpty && validSelection.count == rows.count
        )
    }

    public func cacheSelected(tids selectedTIDs: Set<String>) async {
        errorMessage = nil
        guard let ownerName = offlineCacheOwnerName else { return }

        let targetTIDs = selectionState(for: selectedTIDs).uncachedSelectedTIDs
        guard !targetTIDs.isEmpty else { return }

        do {
            var didEnqueueWork = false
            for chapter in panel.displayChapters where targetTIDs.contains(chapter.tid) {
                let result = try await offlineCacheStore.enqueueMangaOfflineCacheWork(
                    MangaOfflineCacheWorkRequest(
                        ownerName: ownerName,
                        tid: chapter.tid,
                        chapterTitle: chapter.rawTitle
                    )
                )
                if case .enqueued = result {
                    didEnqueueWork = true
                }
            }
            if didEnqueueWork {
                try await continueOfflineCacheQueueIfAllowed()
            }
            await refreshRows()
        } catch {
            YamiboLog.offlineCache.error("Failed to cache selected manga chapters: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            await refreshRows()
        }
    }

    public func deleteSelected(tids selectedTIDs: Set<String>) async {
        errorMessage = nil
        guard let ownerName = offlineCacheOwnerName else { return }
        let targetTIDs = selectionState(for: selectedTIDs).removableSelectedTIDs
        guard !targetTIDs.isEmpty else { return }

        do {
            for chapter in panel.displayChapters where targetTIDs.contains(chapter.tid) {
                try await offlineCacheStore.removeMangaOfflineCacheMembership(ownerName: ownerName, tid: chapter.tid)
            }
            await refreshRows()
        } catch {
            YamiboLog.offlineCache.error("Failed to delete selected manga offline cache chapters: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    public func clearPrompt() {
        prompt = nil
    }

    private func startObservingOfflineCacheUpdates() {
        guard offlineCacheUpdatesTask == nil else { return }
        let updates = offlineCacheStore.offlineCacheUpdates()
        offlineCacheUpdatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refreshRows()
            }
        }
    }

    private func continueOfflineCacheQueueIfAllowed() async throws {
        let works = await mangaQueueWorks()
        guard works.allSatisfy({ $0.state != .failed }) else { return }
        guard let controller = await offlineCacheController() else { return }
        try await controller.continueQueue()
    }

    private func mangaQueueWorks() async -> [OfflineCacheQueueWorkProjection] {
        (await offlineCacheStore.offlineCacheQueueWorks()).filter { $0.id.readerKind == .manga }
    }

    private func offlineCacheController() async -> (any OfflineCacheQueueControlling)? {
        if let offlineCacheQueueController {
            return offlineCacheQueueController
        }
        guard let offlineCacheQueueControllerProvider else { return nil }
        let controller = await offlineCacheQueueControllerProvider()
        offlineCacheQueueController = controller
        return controller
    }

    private var presentationTitle: String {
        let title = context.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? panel.directoryTitle : title
    }

    private var offlineCacheOwnerName: String? {
        let ownerName = panel.directoryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownerName.isEmpty ? nil : ownerName
    }

    private func localFavoriteItem() async -> FavoriteItem? {
        guard let document = try? await localFavoriteLibraryStore.load() else { return nil }
        // A `.mangaThread` favorite is keyed by its own chapter thread id now
        // (no merged-directory identity left to look up by directoryTitle —
        // smart-comic-mode Phase A decision #3/#9), so a direct threadID
        // match is the only lookup that still applies.
        return document.items.first { item in
            item.target.threadID == context.originalThreadID
        }
    }

}

