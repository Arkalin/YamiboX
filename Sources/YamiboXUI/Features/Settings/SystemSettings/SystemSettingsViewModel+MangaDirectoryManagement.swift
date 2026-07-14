import Foundation
import YamiboXCore

// MARK: - Manga directory management page

extension SystemSettingsViewModel {

    func refreshMangaDirectoryManagement() async {
        activeAction = .loading
        defer { activeAction = nil }

        await refreshMangaDirectoryManagementRows()
    }

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

    var isMangaDirectoryManagementSelectionComplete: Bool {
        let visibleIDs = Set(mangaDirectoryManagementRows.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedMangaDirectoryIDs)
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
        await refreshStorageUsage()
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
