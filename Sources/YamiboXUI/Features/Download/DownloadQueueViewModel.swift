import Foundation
import Observation
import YamiboXCore

public protocol DownloadQueueControlling: Sendable {
    func continueQueue() async throws
    func pauseQueue() async throws
    func cancelWork(id: DownloadWorkID) async throws
    func cancelWorks(ids: [DownloadWorkID]) async throws
    func cancelGroup(id: DownloadGroupID) async throws
}

public extension DownloadQueueControlling {
    func cancelWork(id: DownloadWorkID) async throws {}
    func cancelWorks(ids: [DownloadWorkID]) async throws {
        for id in ids { try await cancelWork(id: id) }
    }
    func cancelGroup(id: DownloadGroupID) async throws {}
}

extension DownloadQueueExecutor: DownloadQueueControlling {}

/// State and commands shared by download management and both readers' sheets, so none of them
/// have to carry unrelated home-screen state just to show the queue.
@MainActor
@Observable
final class DownloadQueueViewModel {
    var runState = DownloadQueueRunState.paused
    var groups: [DownloadQueueOwnerGroup] = []
    var entryCount = 0
    private var summaryFailedCount = 0
    var isLoading = false
    var isCommandRunning = false
    var selectedWorkIDs: Set<DownloadWorkID> = []
    var isSelectionMode = false
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?
    private(set) var loadFailure: LoadFailureDetails?

    private let dependencies: DownloadQueueDependencies
    private let injectedController: (any DownloadQueueControlling)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var directoryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sessionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var displayedGeneration: UUID?
    @ObservationIgnored private var visibleConsumers = 0
    @ObservationIgnored private var directoryCache: [String: MangaDirectory] = [:]
    @ObservationIgnored private var loadedDirectoryKeys: Set<String> = []

    init(
        dependencies: DownloadQueueDependencies,
        controller: (any DownloadQueueControlling)? = nil
    ) {
        self.dependencies = dependencies
        self.injectedController = controller
    }

    deinit {
        updatesTask?.cancel()
        directoryUpdatesTask?.cancel()
        sessionUpdatesTask?.cancel()
    }

    var isEmpty: Bool {
        entryCount == 0
    }

    var showsControls: Bool {
        !isEmpty
    }

    var failedCount: Int { summaryFailedCount }

    var summaryText: String {
        if loadFailure != nil { return L10n.string("common.load_failed") }
        if isLoading && isEmpty { return L10n.string("common.loading") }
        if isEmpty { return L10n.string("downloads.queue_empty") }
        var parts = [L10n.string("mine.download_queue.chapter_count_format", entryCount)]
        parts.append(L10n.string(runState == .running ? "mine.download_queue.running" : "mine.download_queue.paused"))
        if failedCount > 0 { parts.append(L10n.string("settings.download.failed_count_format", failedCount)) }
        return parts.joined(separator: " · ")
    }

    var selectedWorkCount: Int {
        selectedWorkIDs.count
    }

    func load() async {
        startObservingUpdates()
        await refresh()
    }

    /// A view task owns heavy queue projection only for its visible lifetime.
    /// A nested owner screen can overlap the root screen without stopping updates.
    func loadWhileVisible() async {
        visibleConsumers += 1
        defer {
            visibleConsumers -= 1
            if visibleConsumers == 0 { revision += 1 }
        }
        await load()
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }
        } catch {}
    }

    func refresh() async {
        guard !isLoading else {
            needsRefresh = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if needsRefresh { Task { await self.refresh() } }
        }
        repeat {
            needsRefresh = false
            await refreshSnapshot()
        } while needsRefresh && !Task.isCancelled
    }

    private func refreshSnapshot() async {
        let refreshRevision = revision
        do {
            let account = try await dependencies.sessionStore.snapshot()
            let store = dependencies.downloadStore
            if displayedGeneration != account.generation {
                directoryCache = [:]
                loadedDirectoryKeys = []
                groups = []
                setSelectionMode(false)
                errorMessage = nil
            }
            if visibleConsumers == 0 {
                let summary = try await store.downloadQueueSummary(readerKind: nil)
                try Task.checkCancellation()
                guard await dependencies.sessionStore.isCurrentGeneration(account.generation), refreshRevision == revision else { return }
                displayedGeneration = account.generation
                entryCount = summary.entryCount
                summaryFailedCount = summary.failedCount
                runState = summary.runState
                loadFailure = nil
                return
            }
            let works = try await store.downloadQueueWorks()
            let nextRunState = try await store.downloadQueueRunState()
            let directoriesByOwnerName = await directoriesByOwnerName(for: works, refreshRevision: refreshRevision)
            try Task.checkCancellation()
            guard await dependencies.sessionStore.isCurrentGeneration(account.generation), refreshRevision == revision else { return }
            if displayedGeneration != account.generation {
                setSelectionMode(false)
                errorMessage = nil
                displayedGeneration = account.generation
            }
            let projection = DownloadQueueProjection.project(
                works: works,
                mangaDirectoriesByOwnerName: directoriesByOwnerName
            )
            // Publish only after every required read succeeds.
            groups = projection.groups.map(DownloadQueueOwnerGroup.init(group:))
            entryCount = projection.unfinishedCount
            summaryFailedCount = works.filter { $0.state == .failed }.count
            runState = nextRunState
            loadFailure = nil

            let visibleIDs = Set(groups.flatMap { group in group.chapters.map(\.id) })
            selectedWorkIDs.formIntersection(visibleIDs)
            if selectedWorkIDs.isEmpty && isEmpty {
                isSelectionMode = false
            }
        } catch {
            if refreshRevision == revision, !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                loadFailure = LoadFailureDetails(error: error)
            }
        }
    }

    func continueQueue() async {
        await performCommand {
            try await (await self.queueController()).continueQueue()
        }
    }

    func pauseQueue() async {
        await performCommand {
            try await (await self.queueController()).pauseQueue()
        }
    }

    func cancelChapter(_ id: DownloadWorkID) async {
        guard let row = chapterRow(id: id) else { return }
        await performCommand {
            try await (await self.queueController()).cancelWork(id: row.id)
        }
    }

    func cancelOwnerGroup(id: DownloadGroupID) async {
        await performCommand {
            try await (await self.queueController()).cancelGroup(id: id)
        }
    }

    func cancelSelectedWorks() async {
        let ids = selectedWorkIDs
        guard !ids.isEmpty else { return }

        await performCommand {
            let controller = await self.queueController()
            let rowsByID = self.chapterRowsByID()
            try await controller.cancelWorks(ids: ids.compactMap { rowsByID[$0]?.id })
        }
        selectedWorkIDs.removeAll()
        isSelectionMode = false
    }

    func setSelectionMode(_ isSelecting: Bool) {
        isSelectionMode = isSelecting
        if !isSelecting {
            selectedWorkIDs.removeAll()
        }
    }

    func toggleWorkSelection(_ id: DownloadWorkID) {
        if selectedWorkIDs.contains(id) {
            selectedWorkIDs.remove(id)
        } else {
            selectedWorkIDs.insert(id)
        }
    }

    func isOwnerSelected(id: DownloadGroupID) -> Bool {
        let ids = workIDs(groupID: id)
        return !ids.isEmpty && ids.isSubset(of: selectedWorkIDs)
    }

    func toggleOwnerSelection(id: DownloadGroupID) {
        let ids = workIDs(groupID: id)
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedWorkIDs) {
            selectedWorkIDs.subtract(ids)
        } else {
            selectedWorkIDs.formUnion(ids)
        }
    }

    func isWorkSelectionComplete(groupID: DownloadGroupID? = nil) -> Bool {
        let ids = workIDs(groupID: groupID)
        return !ids.isEmpty && ids.isSubset(of: selectedWorkIDs)
    }

    func toggleAllWorks(groupID: DownloadGroupID? = nil) {
        let ids = workIDs(groupID: groupID)
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedWorkIDs) {
            selectedWorkIDs.subtract(ids)
        } else {
            selectedWorkIDs.formUnion(ids)
        }
    }

    private func workIDs(groupID: DownloadGroupID?) -> Set<DownloadWorkID> {
        let scopedGroups =
            groupID.map { id in
                groups.filter { $0.id == id }
            } ?? groups
        return Set(
            scopedGroups.flatMap { group in
                group.chapters.map(\.id)
            })
    }

    private func chapterRow(id: DownloadWorkID) -> DownloadQueueChapterRow? {
        chapterRowsByID()[id]
    }

    private func chapterRowsByID() -> [DownloadWorkID: DownloadQueueChapterRow] {
        Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.chapters).map { ($0.id, $0) }
        )
    }

    private func performCommand(_ command: @escaping @MainActor () async throws -> Void) async {
        guard !isCommandRunning else { return }
        isCommandRunning = true
        defer { isCommandRunning = false }

        do {
            try await command()
            errorMessage = nil
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
        await refresh()
    }

    private func queueController() async -> any DownloadQueueControlling {
        if let injectedController {
            return injectedController
        }

        // Composition-owned executors are scoped to the current account
        // generation. This model can outlive that scope, so reacquire one for
        // each command instead of retaining a retired executor.
        return await dependencies.makeDownloadQueueExecutor()
    }

    private func startObservingUpdates() {
        guard updatesTask == nil else { return }
        let store = dependencies.downloadStore
        let updates = store.downloadUpdates()
        updatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        let directoryUpdates = dependencies.mangaDirectoryStore.changes()
        directoryUpdatesTask = Task { @MainActor [weak self] in
            for await _ in directoryUpdates {
                guard !Task.isCancelled, let self else { return }
                directoryCache = [:]
                loadedDirectoryKeys = []
                revision += 1
                if visibleConsumers > 0 { await refresh() }
            }
        }
        let sessionChanges = dependencies.sessionStore.changes()
        sessionUpdatesTask = Task { @MainActor [weak self] in
            for await _ in sessionChanges {
                guard !Task.isCancelled, let self else { return }
                let generation = try? await dependencies.sessionStore.snapshot().generation
                guard generation != displayedGeneration else { continue }
                revision += 1
                groups = []
                directoryCache = [:]
                loadedDirectoryKeys = []
                entryCount = 0
                summaryFailedCount = 0
                setSelectionMode(false)
                loadFailure = nil
                errorMessage = nil
                await refresh()
            }
        }
    }

    private func directoriesByOwnerName(
        for works: [DownloadQueueWorkProjection],
        refreshRevision: Int
    ) async -> [String: MangaDirectory] {
        var directoriesByOwnerName: [String: MangaDirectory] = [:]
        for work in works.sorted(by: { $0.insertionIndex < $1.insertionIndex }) {
            guard work.groupID.readerKind == .manga else { continue }
            guard directoriesByOwnerName[work.groupID.ownerKey] == nil else { continue }
            let key = work.groupID.ownerKey
            if loadedDirectoryKeys.contains(key) {
                directoriesByOwnerName[key] = directoryCache[key]
                continue
            }
            do {
                let directory = try await dependencies.mangaDirectoryStore.directory(
                    id: MangaDirectoryID(rawValue: work.groupID.ownerKey))
                guard refreshRevision == revision, !Task.isCancelled else { return [:] }
                if let directory {
                    directoriesByOwnerName[key] = directory
                    directoryCache[key] = directory
                }
                loadedDirectoryKeys.insert(key)
            } catch {
                YamiboLog.download.warning("Failed to load manga directory metadata for offline download queue owner: \(error)")
            }
        }
        return directoriesByOwnerName
    }
}
