import Foundation
import Observation
import YamiboXCore

public protocol OfflineCacheQueueControlling: Sendable {
    func continueQueue() async throws
    func pauseQueue() async throws
    func cancelWork(id: OfflineCacheWorkID) async throws
    func cancelGroup(id: OfflineCacheGroupID) async throws
}

public extension OfflineCacheQueueControlling {
    func cancelWork(id: OfflineCacheWorkID) async throws {}
    func cancelGroup(id: OfflineCacheGroupID) async throws {}
}

extension OfflineCacheQueueExecutor: OfflineCacheQueueControlling {}

/// State and commands for the offline-cache download queue screens. Shared by
/// the Mine tab's queue entry and both readers' cache sheets, so none of them
/// have to carry unrelated home-screen state just to show the queue.
@MainActor
@Observable
final class OfflineCacheQueueViewModel {
    var runState = OfflineCacheQueueRunState.paused
    var groups: [OfflineCacheQueueOwnerGroup] = []
    var entryCount = 0
    var isLoading = false
    var isCommandRunning = false
    var selectedWorkIDs: Set<OfflineCacheWorkID> = []
    var isSelectionMode = false
    var errorMessage: String?

    private let dependencies: AccountDependencies
    @ObservationIgnored private var controller: (any OfflineCacheQueueControlling)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(
        dependencies: AccountDependencies,
        controller: (any OfflineCacheQueueControlling)? = nil
    ) {
        self.dependencies = dependencies
        self.controller = controller
    }

    deinit {
        updatesTask?.cancel()
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

        let store = dependencies.offlineCacheStore
        let works = await store.offlineCacheQueueWorks()
        let directoriesByOwnerName = await directoriesByOwnerName(for: works)
        let projection = OfflineCacheQueueProjection.project(
            works: works,
            mangaDirectoriesByOwnerName: directoriesByOwnerName
        )
        groups = projection.groups.map(OfflineCacheQueueOwnerGroup.init(group:))
        entryCount = projection.unfinishedCount
        runState = await store.offlineCacheQueueRunState()

        let visibleIDs = Set(groups.flatMap { group in group.chapters.map(\.id) })
        selectedWorkIDs.formIntersection(visibleIDs)
        if selectedWorkIDs.isEmpty && isEmpty {
            isSelectionMode = false
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

    func cancelChapter(_ id: OfflineCacheWorkID) async {
        guard let row = chapterRow(id: id) else { return }
        await performCommand {
            try await (await self.queueController()).cancelWork(id: row.id)
        }
    }

    func cancelOwnerGroup(id: OfflineCacheGroupID) async {
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

    func toggleWorkSelection(_ id: OfflineCacheWorkID) {
        if selectedWorkIDs.contains(id) {
            selectedWorkIDs.remove(id)
        } else {
            selectedWorkIDs.insert(id)
        }
    }

    func isOwnerSelected(id: OfflineCacheGroupID) -> Bool {
        let ids = workIDs(groupID: id)
        return !ids.isEmpty && ids.isSubset(of: selectedWorkIDs)
    }

    func toggleOwnerSelection(id: OfflineCacheGroupID) {
        let ids = workIDs(groupID: id)
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedWorkIDs) {
            selectedWorkIDs.subtract(ids)
        } else {
            selectedWorkIDs.formUnion(ids)
        }
    }

    func isWorkSelectionComplete(groupID: OfflineCacheGroupID? = nil) -> Bool {
        let ids = workIDs(groupID: groupID)
        return !ids.isEmpty && ids.isSubset(of: selectedWorkIDs)
    }

    func toggleAllWorks(groupID: OfflineCacheGroupID? = nil) {
        let ids = workIDs(groupID: groupID)
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: selectedWorkIDs) {
            selectedWorkIDs.subtract(ids)
        } else {
            selectedWorkIDs.formUnion(ids)
        }
    }

    private func workIDs(groupID: OfflineCacheGroupID?) -> Set<OfflineCacheWorkID> {
        let scopedGroups = groupID.map { id in
            groups.filter { $0.id == id }
        } ?? groups
        return Set(scopedGroups.flatMap { group in
            group.chapters.map(\.id)
        })
    }

    private func chapterRow(id: OfflineCacheWorkID) -> OfflineCacheQueueChapterRow? {
        chapterRowsByID()[id]
    }

    private func chapterRowsByID() -> [OfflineCacheWorkID: OfflineCacheQueueChapterRow] {
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
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    private func queueController() async -> any OfflineCacheQueueControlling {
        if let controller {
            return controller
        }

        let executor = await dependencies.makeOfflineCacheQueueExecutor()
        controller = executor
        return executor
    }

    private func startObservingUpdates() {
        guard updatesTask == nil else { return }
        let store = dependencies.offlineCacheStore
        let updates = store.offlineCacheUpdates()
        updatesTask = Task { @MainActor [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func directoriesByOwnerName(
        for works: [OfflineCacheQueueWorkProjection]
    ) async -> [String: MangaDirectory] {
        var directoriesByOwnerName: [String: MangaDirectory] = [:]
        for work in works.sorted(by: { $0.insertionIndex < $1.insertionIndex }) {
            guard work.groupID.readerKind == .manga else { continue }
            guard directoriesByOwnerName[work.groupID.ownerKey] == nil else { continue }
            do {
                if let directory = try await dependencies.mangaDirectoryStore.directory(named: work.groupID.ownerKey) {
                    directoriesByOwnerName[work.groupID.ownerKey] = directory
                }
            } catch {
                YamiboLog.offlineCache.warning("Failed to load manga directory metadata for offline cache queue owner: \(error)")
            }
        }
        return directoriesByOwnerName
    }
}
