import Foundation
import Observation
import YamiboXCore

/// State and commands for the manga directory management page.
@MainActor
@Observable
final class MangaDirectoryManagementViewModel: SystemSettingsActivityReporting {
    var mangaDirectoryManagementRows: [MangaDirectoryManagementRow] = []
    var selectedMangaDirectoryIDs: Set<String> = []
    var isMangaDirectoryManagementSelectionMode = false
    var pendingMangaDirectoryManagementConfirmation: MangaDirectoryManagementConfirmation?

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    /// Deletions here shrink the Storage page's manga-directory figure, so
    /// this page refreshes the shared usage model rather than a private
    /// counter.
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

    var mangaDirectoryManagementIsEmpty: Bool {
        mangaDirectoryManagementRows.isEmpty
    }

    var selectedMangaDirectoryCount: Int {
        selectedMangaDirectoryIDs.count
    }

    var mangaDirectoryManagementCanDeleteSelected: Bool {
        !selectedMangaDirectoryIDs.isEmpty && activeAction != .clearingMangaDirectory
    }

    var isMangaDirectoryManagementSelectionComplete: Bool {
        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedMangaDirectoryIDs)
    }

    func restoreDefaultsAfterApplicationReset() {
        mangaDirectoryManagementRows = []
        selectedMangaDirectoryIDs = []
        isMangaDirectoryManagementSelectionMode = false
        pendingMangaDirectoryManagementConfirmation = nil
    }

    // MARK: - Loading

    func refreshMangaDirectoryManagement() async {
        activeAction = .loading
        defer { activeAction = nil }

        await refreshMangaDirectoryManagementRows()
    }

    // MARK: - Deletion requests and confirmation

    func requestMangaDirectoryDeletion(id: String) {
        prepareMangaDirectoryManagementConfirmation(ids: [id])
    }

    func requestSelectedMangaDirectoryDeletion() {
        prepareMangaDirectoryManagementConfirmation(ids: Array(selectedMangaDirectoryIDs))
    }

    func cancelMangaDirectoryManagementConfirmation() {
        pendingMangaDirectoryManagementConfirmation = nil
    }

    func confirmPendingMangaDirectoryManagementDeletion() async -> Bool {
        guard let confirmation = pendingMangaDirectoryManagementConfirmation else { return false }
        return await confirmMangaDirectoryManagementDeletion(confirmation)
    }

    func confirmMangaDirectoryManagementDeletion(_ confirmation: MangaDirectoryManagementConfirmation) async -> Bool {
        await clearMangaDirectories(ids: confirmation.directoryIDs)
    }

    // MARK: - Selection

    func setMangaDirectoryManagementSelectionMode(_ isSelecting: Bool) {
        isMangaDirectoryManagementSelectionMode = isSelecting
        if !isSelecting {
            selectedMangaDirectoryIDs.removeAll()
        }
    }

    func toggleMangaDirectoryManagementSelection(id: String) {
        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        guard visibleIDs.contains(id) else { return }
        if selectedMangaDirectoryIDs.contains(id) {
            selectedMangaDirectoryIDs.remove(id)
        } else {
            selectedMangaDirectoryIDs.insert(id)
        }
    }

    /// Selecting every visible row and deleting the selection is how this
    /// screen supports "clear all" — the same select-all-then-delete flow the
    /// offline cache management screen already uses, rather than a second,
    /// separate destructive action.
    func toggleAllMangaDirectoryManagementRows() {
        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        guard !visibleIDs.isEmpty else { return }

        if visibleIDs.isSubset(of: selectedMangaDirectoryIDs) {
            selectedMangaDirectoryIDs.subtract(visibleIDs)
        } else {
            selectedMangaDirectoryIDs.formUnion(visibleIDs)
        }
    }

    // MARK: - Private

    /// Refreshes rows/selection/confirmation unconditionally, even when a
    /// directory partway through the batch fails to delete — the refresh's
    /// own `formIntersection` against the store's real current directories
    /// (in `refreshMangaDirectoryManagementRows`) is what reconciles
    /// `selectedMangaDirectoryIDs` to reality, rather than assuming the whole
    /// batch either fully succeeded or fully no-opped.
    private func clearMangaDirectories(ids: [String]) async -> Bool {
        let normalizedIDs = normalizedMangaDirectoryIDs(ids)
        guard !normalizedIDs.isEmpty else { return false }

        activeAction = .clearingMangaDirectory
        defer { activeAction = nil }

        var deletionError: Error?
        for id in normalizedIDs {
            do {
                try await dependencies.mangaDirectoryStore.deleteDirectory(named: id)
            } catch {
                deletionError = error
                break
            }
        }

        pendingMangaDirectoryManagementConfirmation = nil
        await storageUsage.refresh()
        await refreshMangaDirectoryManagementRows()
        if selectedMangaDirectoryIDs.isEmpty {
            isMangaDirectoryManagementSelectionMode = false
        }

        if let deletionError {
            errorMessage = deletionError.localizedDescription
            return false
        }
        return true
    }

    private func refreshMangaDirectoryManagementRows() async {
        let summaries = await dependencies.mangaDirectoryStore.allDirectorySummaries()
        mangaDirectoryManagementRows = summaries
            .map(MangaDirectoryManagementRow.init(summary:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        selectedMangaDirectoryIDs.formIntersection(visibleIDs)
        if selectedMangaDirectoryIDs.isEmpty && mangaDirectoryManagementRows.isEmpty {
            isMangaDirectoryManagementSelectionMode = false
        }
    }

    private func prepareMangaDirectoryManagementConfirmation(ids: [String]) {
        let normalizedIDs = normalizedMangaDirectoryIDs(ids)
        guard !normalizedIDs.isEmpty else { return }
        let rowsByID = Dictionary(uniqueKeysWithValues: mangaDirectoryManagementRows.map { ($0.id, $0) })
        pendingMangaDirectoryManagementConfirmation = MangaDirectoryManagementConfirmation(
            directoryIDs: normalizedIDs,
            titles: normalizedIDs.map { rowsByID[$0]?.title ?? $0 }
        )
    }

    private func normalizedMangaDirectoryIDs(_ ids: [String]) -> [String] {
        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        var seen: Set<String> = []
        return ids
            .filter { visibleIDs.contains($0) && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
