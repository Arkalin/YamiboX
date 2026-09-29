import Foundation
import Observation
import YamiboXCore

/// State and commands for the offline download management page and its
/// per-group drill-down screen.
@MainActor
@Observable
final class DownloadManagementViewModel: SystemSettingsActivityReporting {
    var downloadManagementRows: [DownloadManagementRow] = []
    var selectedDownloadGroupIDs: Set<DownloadGroupID> = []
    var isDownloadManagementSelectionMode = false
    var pendingDownloadManagementConfirmation: DownloadManagementConfirmation?
    private(set) var loadFailure: LoadFailureDetails?

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    /// Deletions here shrink the Storage page's downloads figure, so this
    /// page refreshes the shared usage model rather than a private counter.
    private let storageUsage: SettingsStorageUsage

    init(
        dependencies: SettingsDependencies,
        activity: SystemSettingsActivity,
        storageUsage: SettingsStorageUsage
    ) {
        self.dependencies = dependencies
        self.activity = activity
        self.storageUsage = storageUsage
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
        downloadManagementRows = []
        selectedDownloadGroupIDs = []
        isDownloadManagementSelectionMode = false
        pendingDownloadManagementConfirmation = nil
        loadFailure = nil
    }

    // MARK: - Loading

    func refreshDownloadManagement() async {
        activeAction = .loading
        defer { activeAction = nil }

        await refreshDownloadManagementRows()
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
        let normalizedGroupIDs = normalizedDownloadGroupIDs(groupIDs)
        let normalizedEntryIDs = normalizedDownloadEntryIDs(entryIDs)
        guard !normalizedGroupIDs.isEmpty || !normalizedEntryIDs.isEmpty else { return false }

        activeAction = .clearingDownload
        defer { activeAction = nil }

        do {
            for groupID in normalizedGroupIDs {
                try await dependencies.downloadStore.removeDownloadGroup(groupID)
            }
            for entryID in normalizedEntryIDs {
                try await dependencies.downloadStore.removeDownloadEntry(entryID)
            }
            pendingDownloadManagementConfirmation = nil
            selectedDownloadGroupIDs.subtract(normalizedGroupIDs)
            if selectedDownloadGroupIDs.isEmpty {
                isDownloadManagementSelectionMode = false
            }
            await storageUsage.refresh()
            await refreshDownloadManagementRows()
            return true
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    private func refreshDownloadManagementRows() async {
        let snapshot: DownloadManagementSnapshot
        do {
            snapshot = try await dependencies.downloadStore.downloadManagementSnapshot()
            try Task.checkCancellation()
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                loadFailure = LoadFailureDetails(error: error)
            }
            return
        }
        loadFailure = nil
        downloadManagementRows = snapshot.groups
            .map(DownloadManagementRow.init(group:))
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
        return groupIDs
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.ownerKey.localizedStandardCompare(rhs.ownerKey) == .orderedAscending
            }
    }

    private func normalizedDownloadEntryIDs(_ entryIDs: [DownloadEntryID]) -> [DownloadEntryID] {
        let visibleIDs = Set(downloadManagementRows.flatMap(\.entries).map(\.id))
        var seen: Set<DownloadEntryID> = []
        return entryIDs
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.ownerKey != rhs.ownerKey {
                    return lhs.ownerKey.localizedStandardCompare(rhs.ownerKey) == .orderedAscending
                }
                return lhs.entryKey.localizedStandardCompare(rhs.entryKey) == .orderedAscending
            }
    }
}
