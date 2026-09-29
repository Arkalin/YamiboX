import Foundation
import Observation
import YamiboXCore

public protocol DownloadQueueControlling: Sendable {
    func continueQueue() async throws
    func pauseQueue() async throws
    func cancelWork(id: DownloadWorkID) async throws
    func cancelGroup(id: DownloadGroupID) async throws
}

public extension DownloadQueueControlling {
    func cancelWork(id: DownloadWorkID) async throws {}
    func cancelGroup(id: DownloadGroupID) async throws {}
}

extension DownloadQueueExecutor: DownloadQueueControlling {}

/// State and commands for the downloads download queue screens. Shared by
/// the Mine tab's queue entry and both readers' download sheets, so none of them
/// have to carry unrelated home-screen state just to show the queue.
@MainActor
@Observable
final class DownloadQueueViewModel {
    var runState = DownloadQueueRunState.paused
    var groups: [DownloadQueueOwnerGroup] = []
    var entryCount = 0
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
    }

    var isEmpty: Bool {
        entryCount == 0
    }

    var showsControls: Bool {
        !isEmpty
    }

    var selectedWorkCount: Int {
        selectedWorkIDs.count
    }

    func load() async {
        startObservingUpdates()
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let store = dependencies.downloadStore
            let works = try await store.downloadQueueWorks()
            let nextRunState = try await store.downloadQueueRunState()
            let directoriesByOwnerName = await directoriesByOwnerName(for: works)
            try Task.checkCancellation()
            let projection = DownloadQueueProjection.project(
                works: works,
                mangaDirectoriesByOwnerName: directoriesByOwnerName
            )
            // Publish only after every required read succeeds.
            groups = projection.groups.map(DownloadQueueOwnerGroup.init(group:))
            entryCount = projection.unfinishedCount
            runState = nextRunState
            loadFailure = nil

            let visibleIDs = Set(groups.flatMap { group in group.chapters.map(\.id) })
            selectedWorkIDs.formIntersection(visibleIDs)
            if selectedWorkIDs.isEmpty && isEmpty {
                isSelectionMode = false
            }
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
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
            for id in ids {
                guard let row = rowsByID[id] else { continue }
                try await controller.cancelWork(id: row.id)
            }
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
        let scopedGroups = groupID.map { id in
            groups.filter { $0.id == id }
        } ?? groups
        return Set(scopedGroups.flatMap { group in
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
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func directoriesByOwnerName(
        for works: [DownloadQueueWorkProjection]
    ) async -> [String: MangaDirectory] {
        var directoriesByOwnerName: [String: MangaDirectory] = [:]
        for work in works.sorted(by: { $0.insertionIndex < $1.insertionIndex }) {
            guard work.groupID.readerKind == .manga else { continue }
            guard directoriesByOwnerName[work.groupID.ownerKey] == nil else { continue }
            do {
                if let directory = try await dependencies.mangaDirectoryStore.directory(id: MangaDirectoryID(rawValue: work.groupID.ownerKey)) {
                    directoriesByOwnerName[work.groupID.ownerKey] = directory
                }
            } catch {
                YamiboLog.download.warning("Failed to load manga directory metadata for offline download queue owner: \(error)")
            }
        }
        return directoriesByOwnerName
    }
}
