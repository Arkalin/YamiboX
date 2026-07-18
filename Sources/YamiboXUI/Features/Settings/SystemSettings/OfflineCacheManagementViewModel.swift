import Foundation
import Observation
import YamiboXCore

/// State and commands for the offline cache management page and its
/// per-group drill-down screen.
@MainActor
@Observable
final class OfflineCacheManagementViewModel: SystemSettingsActivityReporting {
    var offlineCacheManagementRows: [OfflineCacheManagementRow] = []
    var selectedOfflineCacheGroupIDs: Set<OfflineCacheGroupID> = []
    var isOfflineCacheManagementSelectionMode = false
    var pendingOfflineCacheManagementConfirmation: OfflineCacheManagementConfirmation?

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    /// Deletions here shrink the Storage page's offline-cache figure, so this
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

    var offlineCacheManagementIsEmpty: Bool {
        offlineCacheManagementRows.isEmpty
    }

    var selectedOfflineCacheGroupCount: Int {
        selectedOfflineCacheGroupIDs.count
    }

    var offlineCacheManagementSelectionActionState: OfflineCacheManagementSelectionActionState {
        OfflineCacheManagementSelectionActionState(
            selectedGroupCount: selectedOfflineCacheGroupIDs.count,
            canDelete: !selectedOfflineCacheGroupIDs.isEmpty
                && activeAction != .clearingOfflineCache
        )
    }

    var isOfflineCacheManagementSelectionComplete: Bool {
        let visibleGroupIDs = Set(offlineCacheManagementRows.map(\.id))
        return !visibleGroupIDs.isEmpty && visibleGroupIDs.isSubset(of: selectedOfflineCacheGroupIDs)
    }

    func restoreDefaultsAfterApplicationReset() {
        offlineCacheManagementRows = []
        selectedOfflineCacheGroupIDs = []
        isOfflineCacheManagementSelectionMode = false
        pendingOfflineCacheManagementConfirmation = nil
    }

    // MARK: - Loading

    func refreshOfflineCacheManagement() async {
        activeAction = .loading
        defer { activeAction = nil }

        await refreshOfflineCacheManagementRows()
    }

    // MARK: - Deletion requests and confirmation

    func requestOfflineCacheGroupDeletion(id: OfflineCacheGroupID) {
        prepareOfflineCacheManagementConfirmation(groupIDs: [id])
    }

    func requestOfflineCacheSwipeGroupDeletion(id: OfflineCacheGroupID) {
        requestOfflineCacheGroupDeletion(id: id)
    }

    func requestOfflineCacheEntryDeletion(id: OfflineCacheEntryID) {
        prepareOfflineCacheManagementConfirmation(entryIDs: [id])
    }

    func requestSelectedOfflineCacheGroupDeletion() {
        prepareOfflineCacheManagementConfirmation(groupIDs: Array(selectedOfflineCacheGroupIDs))
    }

    func cancelOfflineCacheManagementConfirmation() {
        pendingOfflineCacheManagementConfirmation = nil
    }

    func confirmPendingOfflineCacheManagementDeletion() async -> Bool {
        guard let confirmation = pendingOfflineCacheManagementConfirmation else { return false }
        return await confirmOfflineCacheManagementDeletion(confirmation)
    }

    func confirmOfflineCacheManagementDeletion(_ confirmation: OfflineCacheManagementConfirmation) async -> Bool {
        await clearOfflineCache(groupIDs: confirmation.groupIDs, entryIDs: confirmation.entryIDs)
    }

    // MARK: - Selection

    func setOfflineCacheManagementSelectionMode(_ isSelecting: Bool) {
        isOfflineCacheManagementSelectionMode = isSelecting
        if !isSelecting {
            selectedOfflineCacheGroupIDs.removeAll()
        }
    }

    func toggleOfflineCacheManagementSelection(id: OfflineCacheGroupID) {
        let visibleIDs = Set(offlineCacheManagementRows.map(\.id))
        guard visibleIDs.contains(id) else { return }
        if selectedOfflineCacheGroupIDs.contains(id) {
            selectedOfflineCacheGroupIDs.remove(id)
        } else {
            selectedOfflineCacheGroupIDs.insert(id)
        }
    }

    func toggleAllOfflineCacheManagementRows() {
        let visibleGroupIDs = Set(offlineCacheManagementRows.map(\.id))
        guard !visibleGroupIDs.isEmpty else { return }

        if visibleGroupIDs.isSubset(of: selectedOfflineCacheGroupIDs) {
            selectedOfflineCacheGroupIDs.subtract(visibleGroupIDs)
        } else {
            selectedOfflineCacheGroupIDs.formUnion(visibleGroupIDs)
        }
    }

    func offlineCacheManagementRow(id: OfflineCacheGroupID) -> OfflineCacheManagementRow? {
        offlineCacheManagementRows.first { $0.id == id }
    }

    // MARK: - Private

    private func clearOfflineCache(groupIDs: [OfflineCacheGroupID], entryIDs: [OfflineCacheEntryID]) async -> Bool {
        let normalizedGroupIDs = normalizedOfflineCacheGroupIDs(groupIDs)
        let normalizedEntryIDs = normalizedOfflineCacheEntryIDs(entryIDs)
        guard !normalizedGroupIDs.isEmpty || !normalizedEntryIDs.isEmpty else { return false }

        activeAction = .clearingOfflineCache
        defer { activeAction = nil }

        do {
            for groupID in normalizedGroupIDs {
                try await dependencies.offlineCacheStore.removeOfflineCacheGroup(groupID)
            }
            for entryID in normalizedEntryIDs {
                try await dependencies.offlineCacheStore.removeOfflineCacheEntry(entryID)
            }
            pendingOfflineCacheManagementConfirmation = nil
            selectedOfflineCacheGroupIDs.subtract(normalizedGroupIDs)
            if selectedOfflineCacheGroupIDs.isEmpty {
                isOfflineCacheManagementSelectionMode = false
            }
            await storageUsage.refresh()
            await refreshOfflineCacheManagementRows()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshOfflineCacheManagementRows() async {
        let snapshot = await dependencies.offlineCacheStore.offlineCacheManagementSnapshot()
        offlineCacheManagementRows = snapshot.groups
            .map(OfflineCacheManagementRow.init(group:))
            .sorted { lhs, rhs in
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.id.ownerKey.localizedStandardCompare(rhs.id.ownerKey) == .orderedAscending
            }

        let visibleIDs = Set(offlineCacheManagementRows.map(\.id))
        selectedOfflineCacheGroupIDs.formIntersection(visibleIDs)
        if selectedOfflineCacheGroupIDs.isEmpty && offlineCacheManagementRows.isEmpty {
            isOfflineCacheManagementSelectionMode = false
        }
    }

    private func prepareOfflineCacheManagementConfirmation(
        groupIDs: [OfflineCacheGroupID] = [],
        entryIDs: [OfflineCacheEntryID] = []
    ) {
        let normalizedGroupIDs = normalizedOfflineCacheGroupIDs(groupIDs)
        let normalizedEntryIDs = normalizedOfflineCacheEntryIDs(entryIDs)
        guard !normalizedGroupIDs.isEmpty || !normalizedEntryIDs.isEmpty else { return }
        let rowsByID = Dictionary(uniqueKeysWithValues: offlineCacheManagementRows.map { ($0.id, $0) })
        let entriesByID = Dictionary(
            uniqueKeysWithValues: offlineCacheManagementRows.flatMap(\.entries).map { ($0.id, $0) }
        )
        pendingOfflineCacheManagementConfirmation = OfflineCacheManagementConfirmation(
            groupIDs: normalizedGroupIDs,
            entryIDs: normalizedEntryIDs,
            titles: normalizedGroupIDs.map { rowsByID[$0]?.title ?? $0.ownerKey }
                + normalizedEntryIDs.map { entriesByID[$0]?.title ?? $0.entryKey }
        )
    }

    private func normalizedOfflineCacheGroupIDs(_ groupIDs: [OfflineCacheGroupID]) -> [OfflineCacheGroupID] {
        let visibleIDs = Set(offlineCacheManagementRows.map(\.id))
        var seen: Set<OfflineCacheGroupID> = []
        return groupIDs
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.ownerKey.localizedStandardCompare(rhs.ownerKey) == .orderedAscending
            }
    }

    private func normalizedOfflineCacheEntryIDs(_ entryIDs: [OfflineCacheEntryID]) -> [OfflineCacheEntryID] {
        let visibleIDs = Set(offlineCacheManagementRows.flatMap(\.entries).map(\.id))
        var seen: Set<OfflineCacheEntryID> = []
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
