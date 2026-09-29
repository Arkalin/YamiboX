import Foundation
import Observation
import YamiboXCore

/// State and commands for the offline download management page and its
/// per-group drill-down screen.
@MainActor
@Observable
final class DownloadManagementViewModel {
    enum Action: Equatable { case loading, clearingDownload }
    private(set) var activeAction: Action?
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?
    var downloadManagementRows: [DownloadManagementRow] = []
    var selectedDownloadGroupIDs: Set<DownloadGroupID> = []
    var isDownloadManagementSelectionMode = false
    var pendingDownloadManagementConfirmation: DownloadManagementConfirmation?
    private(set) var loadFailure: LoadFailureDetails?

    private let downloadStore: any DownloadManagementStoring
    private let sessionStore: SessionStore
    private let onDeletion: @MainActor () async -> Void
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var displayedGeneration: UUID?
    @ObservationIgnored private var loadingID: UUID?

    init(
        downloadStore: any DownloadManagementStoring,
        sessionStore: SessionStore,
        onDeletion: @escaping @MainActor () async -> Void = {}
    ) {
        self.downloadStore = downloadStore
        self.sessionStore = sessionStore
        self.onDeletion = onDeletion
    }

    var downloadManagementIsEmpty: Bool {
        downloadManagementRows.isEmpty
    }

    var selectedDownloadGroupCount: Int {
        selectedDownloadGroupIDs.count
    }

    var downloadManagementSelectionActionState: DownloadManagementSelectionActionState {
        DownloadManagementSelectionActionState(
            selectedGroupCount: selectedDownloadGroupIDs.count,
            canDelete: !selectedDownloadGroupIDs.isEmpty
                && activeAction != .clearingDownload
        )
    }

    var isDownloadManagementSelectionComplete: Bool {
        let visibleGroupIDs = Set(downloadManagementRows.map(\.id))
        return !visibleGroupIDs.isEmpty && visibleGroupIDs.isSubset(of: selectedDownloadGroupIDs)
    }

    func restoreDefaultsAfterApplicationReset() {
        revision += 1
        downloadManagementRows = []
        selectedDownloadGroupIDs = []
        isDownloadManagementSelectionMode = false
        pendingDownloadManagementConfirmation = nil
        loadFailure = nil
        errorMessage = nil
        errorDetails = nil
    }

    // MARK: - Loading

    func refreshDownloadManagement() async {
        guard activeAction == nil else {
            needsRefresh = true
            return
        }
        let id = UUID()
        loadingID = id
        activeAction = .loading
        defer {
            if loadingID == id && activeAction == .loading {
                loadingID = nil
                activeAction = nil
                // A pushed page may request its load while the disappearing
                // page's task is being cancelled. Do not lose that request.
                if needsRefresh { Task { await self.refreshDownloadManagement() } }
            }
        }
        repeat {
            needsRefresh = false
            await refreshDownloadManagementRows()
        } while needsRefresh && loadingID == id && !Task.isCancelled
    }

    /// Throttle bursty progress notifications without losing the final update.
    /// The view owns cancellation, so hidden pages do not scan the disk.
    func observeUpdates() async {
        let updates = downloadStore.downloadUpdates()
        await refreshDownloadManagement()
        for await _ in updates {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await refreshDownloadManagement()
        }
    }

    func observeSession() async {
        for await _ in sessionStore.changes() {
            guard !Task.isCancelled else { return }
            let generation = try? await sessionStore.snapshot().generation
            guard generation != displayedGeneration else { continue }
            restoreDefaultsAfterApplicationReset()
            await refreshDownloadManagement()
        }
    }

    // MARK: - Deletion requests and confirmation

    func requestDownloadGroupDeletion(id: DownloadGroupID) {
        prepareDownloadManagementConfirmation(groupIDs: [id])
    }

    func requestDownloadSwipeGroupDeletion(id: DownloadGroupID) {
        requestDownloadGroupDeletion(id: id)
    }

    func requestDownloadEntryDeletion(id: DownloadEntryID) {
        prepareDownloadManagementConfirmation(entryIDs: [id])
    }

    func requestSelectedDownloadGroupDeletion() {
        prepareDownloadManagementConfirmation(groupIDs: Array(selectedDownloadGroupIDs))
    }

    func cancelDownloadManagementConfirmation() {
        pendingDownloadManagementConfirmation = nil
    }

    func confirmPendingDownloadManagementDeletion() async -> Bool {
        guard let confirmation = pendingDownloadManagementConfirmation else { return false }
        return await confirmDownloadManagementDeletion(confirmation)
    }

    func confirmDownloadManagementDeletion(_ confirmation: DownloadManagementConfirmation) async -> Bool {
        await clearDownload(groupIDs: confirmation.groupIDs, entryIDs: confirmation.entryIDs)
    }

    // MARK: - Selection

    func setDownloadManagementSelectionMode(_ isSelecting: Bool) {
        isDownloadManagementSelectionMode = isSelecting
        if !isSelecting {
            selectedDownloadGroupIDs.removeAll()
        }
    }

    func toggleDownloadManagementSelection(id: DownloadGroupID) {
        let visibleIDs = Set(downloadManagementRows.map(\.id))
        guard visibleIDs.contains(id) else { return }
        if selectedDownloadGroupIDs.contains(id) {
            selectedDownloadGroupIDs.remove(id)
        } else {
            selectedDownloadGroupIDs.insert(id)
        }
    }

    func toggleAllDownloadManagementRows() {
        let visibleGroupIDs = Set(downloadManagementRows.map(\.id))
        guard !visibleGroupIDs.isEmpty else { return }

        if visibleGroupIDs.isSubset(of: selectedDownloadGroupIDs) {
            selectedDownloadGroupIDs.subtract(visibleGroupIDs)
        } else {
            selectedDownloadGroupIDs.formUnion(visibleGroupIDs)
        }
    }

    func downloadManagementRow(id: DownloadGroupID) -> DownloadManagementRow? {
        downloadManagementRows.first { $0.id == id }
    }

    // MARK: - Private

    private func clearDownload(groupIDs: [DownloadGroupID], entryIDs: [DownloadEntryID]) async -> Bool {
        guard activeAction != .clearingDownload else { return false }
        let normalizedGroupIDs = normalizedDownloadGroupIDs(groupIDs)
        let normalizedEntryIDs = normalizedDownloadEntryIDs(entryIDs)
        guard !normalizedGroupIDs.isEmpty || !normalizedEntryIDs.isEmpty else { return false }

        revision += 1
        loadingID = nil
        let commandRevision = revision
        activeAction = .clearingDownload
        defer {
            activeAction = nil
            if needsRefresh { Task { await self.refreshDownloadManagement() } }
        }

        do {
            let account = try await sessionStore.snapshot()
            for groupID in normalizedGroupIDs {
                guard await sessionStore.isCurrentGeneration(account.generation), commandRevision == revision else { return false }
                try await downloadStore.removeDownloadGroup(groupID)
            }
            for entryID in normalizedEntryIDs {
                guard await sessionStore.isCurrentGeneration(account.generation), commandRevision == revision else { return false }
                try await downloadStore.removeDownloadEntry(entryID)
            }
            guard commandRevision == revision else { return false }
            pendingDownloadManagementConfirmation = nil
            selectedDownloadGroupIDs.subtract(normalizedGroupIDs)
            if selectedDownloadGroupIDs.isEmpty {
                isDownloadManagementSelectionMode = false
            }
            await onDeletion()
            await refreshDownloadManagementRows()
            return true
        } catch {
            if commandRevision == revision, !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            needsRefresh = true
            return false
        }
    }

    private func refreshDownloadManagementRows() async {
        let refreshRevision = revision
        let snapshot: DownloadManagementSnapshot
        do {
            let account = try await sessionStore.snapshot()
            snapshot = try await downloadStore.downloadManagementSnapshot()
            try Task.checkCancellation()
            guard await sessionStore.isCurrentGeneration(account.generation), refreshRevision == revision else { return }
            if displayedGeneration != account.generation {
                setDownloadManagementSelectionMode(false)
                pendingDownloadManagementConfirmation = nil
                errorMessage = nil
                errorDetails = nil
                displayedGeneration = account.generation
            }
        } catch {
            if refreshRevision == revision, !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                loadFailure = LoadFailureDetails(error: error)
            }
            return
        }
        loadFailure = nil
        downloadManagementRows = snapshot.groups
            .map(DownloadManagementRow.init(group:))
            .filter { !$0.entries.isEmpty }
            .sorted { lhs, rhs in
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.id.ownerKey.localizedStandardCompare(rhs.id.ownerKey) == .orderedAscending
            }

        let visibleIDs = Set(downloadManagementRows.map(\.id))
        selectedDownloadGroupIDs.formIntersection(visibleIDs)
        if selectedDownloadGroupIDs.isEmpty && downloadManagementRows.isEmpty {
            isDownloadManagementSelectionMode = false
        }
    }

    private func prepareDownloadManagementConfirmation(
        groupIDs: [DownloadGroupID] = [],
        entryIDs: [DownloadEntryID] = []
    ) {
        let normalizedGroupIDs = normalizedDownloadGroupIDs(groupIDs)
        let normalizedEntryIDs = normalizedDownloadEntryIDs(entryIDs)
        guard !normalizedGroupIDs.isEmpty || !normalizedEntryIDs.isEmpty else { return }
        let rowsByID = Dictionary(uniqueKeysWithValues: downloadManagementRows.map { ($0.id, $0) })
        let entriesByID = Dictionary(
            uniqueKeysWithValues: downloadManagementRows.flatMap(\.entries).map { ($0.id, $0) }
        )
        pendingDownloadManagementConfirmation = DownloadManagementConfirmation(
            groupIDs: normalizedGroupIDs,
            entryIDs: normalizedEntryIDs,
            titles: normalizedGroupIDs.map { rowsByID[$0]?.title ?? $0.ownerKey }
                + normalizedEntryIDs.map { entriesByID[$0]?.title ?? $0.entryKey }
        )
    }

    private func normalizedDownloadGroupIDs(_ groupIDs: [DownloadGroupID]) -> [DownloadGroupID] {
        let visibleIDs = Set(downloadManagementRows.map(\.id))
        var seen: Set<DownloadGroupID> = []
        return
            groupIDs
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.ownerKey.localizedStandardCompare(rhs.ownerKey) == .orderedAscending
            }
    }

    private func normalizedDownloadEntryIDs(_ entryIDs: [DownloadEntryID]) -> [DownloadEntryID] {
        let visibleIDs = Set(downloadManagementRows.flatMap(\.entries).map(\.id))
        var seen: Set<DownloadEntryID> = []
        return
            entryIDs
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.ownerKey != rhs.ownerKey {
                    return lhs.ownerKey.localizedStandardCompare(rhs.ownerKey) == .orderedAscending
                }
                return lhs.entryKey.localizedStandardCompare(rhs.entryKey) == .orderedAscending
            }
    }
}
