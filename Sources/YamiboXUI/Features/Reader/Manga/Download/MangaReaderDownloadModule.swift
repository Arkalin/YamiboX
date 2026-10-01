import Combine
import Foundation
import YamiboXCore

public struct MangaReaderDownloadRow: Hashable, Identifiable, Sendable {
    public var chapter: MangaChapter
    public var state: MangaDownloadState

    public var id: String { chapter.tid }

    public init(chapter: MangaChapter, state: MangaDownloadState) {
        self.chapter = chapter
        self.state = state
    }
}

public enum MangaReaderDownloadPrompt: Equatable, Identifiable, Sendable {
    case addFavorite(title: String)

    public var id: String {
        switch self {
        case .addFavorite:
            "addFavorite"
        }
    }
}

@MainActor
public final class MangaReaderDownloadViewModel: ObservableObject {
    @Published public private(set) var rows: [MangaReaderDownloadRow] = []
    @Published public private(set) var favorite: Favorite?
    @Published public private(set) var prompt: MangaReaderDownloadPrompt?
    @Published public private(set) var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    @Published var errorDetails: LoadFailureDetails?
    @Published public private(set) var downloadQueueEntryCount = 0

    private let context: MangaLaunchContext
    private let panel: MangaDirectoryPanelPresentation
    private let localFavoriteLibraryStore: FavoriteLibraryStore
    private let downloadStore: any MangaDownloadStoring & DownloadQueueStoring
    private let downloadQueueControllerProvider: (@Sendable () async -> any DownloadQueueControlling)?
    private var downloadUpdatesTask: Task<Void, Never>?
    private var pendingRowsRefreshTask: Task<Void, Never>?
    private var isRefreshingRows = false
    private var needsRowsRefresh = false

    public init(
        context: MangaLaunchContext,
        panel: MangaDirectoryPanelPresentation,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        downloadStore: any MangaDownloadStoring & DownloadQueueStoring,
        downloadQueueControllerProvider: (@Sendable () async -> any DownloadQueueControlling)? = nil
    ) {
        self.context = context
        self.panel = panel
        self.localFavoriteLibraryStore = localFavoriteLibraryStore
        self.downloadStore = downloadStore
        self.downloadQueueControllerProvider = downloadQueueControllerProvider
    }

    deinit {
        downloadUpdatesTask?.cancel()
        pendingRowsRefreshTask?.cancel()
    }

    public var allChapterTIDs: Set<String> {
        Set(rows.map(\.chapter.tid))
    }

    public func load() async {
        startObservingDownloadUpdates()
        favorite = await localFavoriteItem()?.favorite(type: .manga)
        await refreshRows()
    }

    public func refreshRows() async {
        guard !Task.isCancelled else { return }
        guard !isRefreshingRows else { needsRowsRefresh = true; return }
        isRefreshingRows = true
        defer {
            isRefreshingRows = false
            // A new caller can request a refresh while a cancelled load is
            // still unwinding. Hand it to a fresh task, not that cancelled task.
            if needsRowsRefresh {
                needsRowsRefresh = false
                pendingRowsRefreshTask = Task { @MainActor [weak self] in
                    await self?.refreshRows()
                }
            }
        }
        repeat {
            needsRowsRefresh = false
            await refreshChapterRows()
            guard !Task.isCancelled else { return }
            await refreshDownloadQueueEntryCount()
        } while needsRowsRefresh && !Task.isCancelled
    }

    private func refreshChapterRows() async {
        let states = if let ownerName = downloadOwnerName {
            await downloadStore.mangaDownloadStates(ownerName: ownerName)
        } else { [String: MangaDownloadState]() }
        guard !Task.isCancelled else { return }
        let nextRows = panel.displayChapters.map {
            MangaReaderDownloadRow(chapter: $0, state: states[$0.tid] ?? .notDownloaded)
        }
        if rows != nextRows { rows = nextRows }
    }

    private func refreshDownloadQueueEntryCount() async {
        do {
            let count = try await downloadStore.downloadQueueSummary(readerKind: .manga).entryCount
            try Task.checkCancellation()
            downloadQueueEntryCount = count
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    public func selectionState(for selectedTIDs: Set<String>) -> ReaderDownloadSelectionState {
        let validSelection = selectedTIDs.intersection(allChapterTIDs)
        let stateByTID = Dictionary(uniqueKeysWithValues: rows.map { ($0.chapter.tid, $0.state) })
        let notDownloaded = validSelection.filter { stateByTID[$0] == .notDownloaded }
        let removable = validSelection.filter { tid in
            switch stateByTID[tid] {
            case .downloaded, .downloading:
                true
            case .notDownloaded, nil:
                false
            }
        }
        return ReaderDownloadSelectionState(
            selectedTIDs: validSelection,
            notDownloadedSelectedTIDs: Set(notDownloaded),
            removableSelectedTIDs: Set(removable),
            canDownload: !notDownloaded.isEmpty,
            canDelete: !removable.isEmpty,
            isAllSelected: !rows.isEmpty && validSelection.count == rows.count
        )
    }

    public func downloadSelected(tids selectedTIDs: Set<String>) async {
        errorMessage = nil
        guard let ownerName = downloadOwnerName else { return }

        let targetTIDs = selectionState(for: selectedTIDs).notDownloadedSelectedTIDs
        guard !targetTIDs.isEmpty else { return }

        do {
            var didEnqueueWork = false
            for chapter in panel.displayChapters where targetTIDs.contains(chapter.tid) {
                let result = try await downloadStore.enqueueMangaDownloadWork(
                    MangaDownloadWorkRequest(
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
                try await continueDownloadQueueIfAllowed()
            }
            await refreshRows()
        } catch {
            YamiboLog.download.error("Failed to download selected manga chapters: \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            await refreshRows()
        }
    }

    public func deleteSelected(tids selectedTIDs: Set<String>) async {
        errorMessage = nil
        guard let ownerName = downloadOwnerName else { return }
        let targetTIDs = selectionState(for: selectedTIDs).removableSelectedTIDs
        guard !targetTIDs.isEmpty else { return }

        do {
            for chapter in panel.displayChapters where targetTIDs.contains(chapter.tid) {
                try await downloadStore.removeMangaDownloadMembership(ownerName: ownerName, tid: chapter.tid)
            }
            await refreshRows()
        } catch {
            YamiboLog.download.error("Failed to delete selected manga offline download chapters: \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    public func clearPrompt() {
        prompt = nil
    }

    private func startObservingDownloadUpdates() {
        guard downloadUpdatesTask == nil else { return }
        let updates = downloadStore.downloadUpdates()
        downloadUpdatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refreshRows()
            }
        }
    }

    private func continueDownloadQueueIfAllowed() async throws {
        let summary = try await downloadStore.downloadQueueSummary(readerKind: .manga)
        guard summary.failedCount == 0 else { return }
        guard let controller = await downloadController() else { return }
        try await controller.continueQueue()
    }

    private func downloadController() async -> (any DownloadQueueControlling)? {
        guard let downloadQueueControllerProvider else { return nil }
        return await downloadQueueControllerProvider()
    }

    private var presentationTitle: String {
        let title = context.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? panel.directoryTitle : title
    }

    private var downloadOwnerName: String? {
        panel.directoryID?.rawValue
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
