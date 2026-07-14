import Foundation
import YamiboXCore

// MARK: - Directory management
//
// The reader's directory command lane: panel-driven update/search, reset,
// rename, chapter deletion, the automatic post-load update, and the
// cooldown/forced-search countdown that the directory panel renders. Every
// mutation republishes reader content through the main file's
// `publishPresentation`, which is why this stays on the view model rather
// than a separate controller — the lane's outputs ARE reader content.
extension MangaReaderViewModel {

    public func updateDirectoryFromPanel() async {
        guard case let .loaded(loaded) = presentation.state else { return }
        await updateDirectory(isForcedSearch: loaded.directoryPanel.shouldForceSearchOnUpdate)
    }

    public func updateDirectory(isForcedSearch: Bool = false) async {
        if isForcedSearch {
            automaticDirectoryUpdateTask?.cancel()
            automaticDirectoryUpdateTask = nil
        }
        await enqueueDirectoryUpdate(isForcedSearch: isForcedSearch, isAutomatic: false)
    }

    public func resetDirectory() async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        invalidateReaderContent()
        directoryMutationGeneration += 1
        let generation = directoryMutationGeneration
        directoryMutationTask = Task { @MainActor [weak self] in
            await self?.performDirectoryReset(mutationGeneration: generation)
        }
        await directoryMutationTask?.value
    }

    public func renameDirectory(cleanBookName: String, searchKeyword: String) async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        invalidateReaderContent()
        directoryMutationGeneration += 1
        let generation = directoryMutationGeneration
        directoryMutationTask = Task { @MainActor [weak self] in
            await self?.performRenameDirectory(
                cleanBookName: cleanBookName,
                searchKeyword: searchKeyword,
                mutationGeneration: generation
            )
        }
        await directoryMutationTask?.value
    }

    public func renameDirectory(with draft: MangaDirectoryEditDraft) async {
        await renameDirectory(
            cleanBookName: draft.cleanBookName,
            searchKeyword: MangaDirectoryWorkflow.searchKeyword(from: draft)
        )
    }

    public func deleteDirectoryChapters(tids: Set<String>) async {
        guard case let .loaded(loaded) = presentation.state else { return }
        let targetTIDs = Set(tids.compactMap(Self.normalizedNonEmpty))
        guard !targetTIDs.isEmpty else { return }
        if let currentChapterTID = loaded.directoryPanel.currentChapterTID,
           targetTIDs.contains(currentChapterTID) {
            return
        }

        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        invalidateReaderContent()
        directoryMutationGeneration += 1
        let generation = directoryMutationGeneration
        directoryMutationTask = Task { @MainActor [weak self] in
            await self?.performDeleteDirectoryChapters(
                tids: targetTIDs,
                mutationGeneration: generation
            )
        }
        await directoryMutationTask?.value
    }

    func startAutomaticDirectoryUpdate() {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = Task { @MainActor [weak self] in
            await self?.enqueueDirectoryUpdate(isForcedSearch: false, isAutomatic: true)
        }
    }

    private func enqueueDirectoryUpdate(isForcedSearch: Bool, isAutomatic: Bool) async {
        if isAutomatic, directoryMutationTask != nil {
            automaticDirectoryUpdateTask = nil
            return
        }

        if !isAutomatic {
            directoryMutationTask?.cancel()
        }

        invalidateReaderContent()
        directoryMutationGeneration += 1
        let generation = directoryMutationGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDirectoryUpdate(
                isForcedSearch: isForcedSearch,
                isAutomatic: isAutomatic,
                mutationGeneration: generation
            )
        }
        directoryMutationTask = task
        await task.value
    }

    private func performDirectoryUpdate(
        isForcedSearch: Bool,
        isAutomatic: Bool,
        mutationGeneration: Int
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)

        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
            if isAutomatic {
                automaticDirectoryUpdateTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let result = try await workflow.updateDirectory(isForcedSearch: isForcedSearch)
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            publishPresentation(workflow.presentation, previousProgressSnapshot: previousProgressSnapshot)
            applyDirectoryCommandCooldown(result)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            YamiboLog.reader.error("Manga directory update failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
        }
    }

    private func performDirectoryReset(mutationGeneration: Int) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)

        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let result = try await workflow.resetDirectory()
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            publishPresentation(workflow.presentation, previousProgressSnapshot: previousProgressSnapshot)
            applyDirectoryCommandCooldown(result)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            YamiboLog.reader.error("Manga directory reset failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
        }
    }

    private func performRenameDirectory(
        cleanBookName: String,
        searchKeyword: String,
        mutationGeneration: Int
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let oldOwnerName = offlineCacheOwnerName
            let updated = try await workflow.renameDirectory(cleanBookName: cleanBookName, searchKeyword: searchKeyword)
            if let oldOwnerName, oldOwnerName != updated.cleanBookName {
                await dependencies.migrateMangaTitleReferences(oldOwnerName, updated.cleanBookName)
            }
            let cacheRenameError: Error?
            if let oldOwnerName,
               oldOwnerName != updated.cleanBookName,
               let offlineCacheStore = dependencies.makeOfflineCacheStore() {
                do {
                    try await offlineCacheStore.renameMangaOfflineCacheOwner(from: oldOwnerName, to: updated.cleanBookName)
                    cacheRenameError = nil
                } catch {
                    YamiboLog.offlineCache.error("Failed to rename offline cache owner directory after manga rename: \(error.localizedDescription)")
                    cacheRenameError = error
                }
            } else {
                cacheRenameError = nil
            }
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            publishPresentation(workflow.presentation, previousProgressSnapshot: previousProgressSnapshot)
            refreshDirectoryPanelTiming(errorMessage: cacheRenameError?.localizedDescription)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            YamiboLog.reader.error("Manga directory rename failed: \(error.localizedDescription)")
            refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
        }
    }

    private func performDeleteDirectoryChapters(
        tids: Set<String>,
        mutationGeneration: Int
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let nextPresentation = try await workflow.deleteDirectoryChapters(tids: tids)
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            YamiboLog.reader.error("Deleting manga directory chapters failed: \(error.localizedDescription)")
            refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
        }
    }

    var currentDirectoryPanelErrorMessage: String? {
        guard case let .loaded(loaded) = presentation.state else { return nil }
        return loaded.directoryPanel.errorMessage
    }

    func refreshDirectoryPanelTiming(errorMessage: String?) {
        setDirectoryPanelCommandState(
            isUpdating: false,
            errorMessage: errorMessage
        )
        updateDirectoryTickTask()
    }

    private func setDirectoryPanelCommandState(
        isUpdating: Bool,
        errorMessage: String?
    ) {
        guard let workflow else { return }
        let now = dependencies.directoryWorkflowConfiguration.now()
        let cooldownRemaining = remainingSecondsValue(until: directoryCooldownExpiresAt, now: now)
        let forcedRemaining = remainingSeconds(until: forcedSearchShortcutExpiresAt, now: now)
        if cooldownRemaining == 0 {
            directoryCooldownExpiresAt = nil
        }
        if forcedRemaining == nil {
            forcedSearchShortcutExpiresAt = nil
        }
        presentation = workflow.updateDirectoryPanelCommandState(
            MangaDirectoryPanelCommandState(
                isUpdating: isUpdating,
                cooldownRemaining: cooldownRemaining,
                forcedSearchShortcutRemaining: forcedRemaining,
                errorMessage: errorMessage
            )
        )
    }

    private func updateDirectoryTickTask() {
        let hasActiveDeadline = directoryCooldownExpiresAt != nil || forcedSearchShortcutExpiresAt != nil
        guard hasActiveDeadline else {
            directoryTickTask?.cancel()
            directoryTickTask = nil
            return
        }
        guard directoryTickTask == nil else { return }

        directoryTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.setDirectoryPanelCommandState(
                    isUpdating: false,
                    errorMessage: self?.currentDirectoryPanelErrorMessage
                )
                guard self?.directoryCooldownExpiresAt != nil || self?.forcedSearchShortcutExpiresAt != nil else {
                    self?.directoryTickTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func remainingSeconds(until deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining)))
    }

    private func remainingSecondsValue(until deadline: Date?, now: Date) -> Int {
        remainingSeconds(until: deadline, now: now) ?? 0
    }

    /// Applies a successful update/reset command's cooldown outcome: an
    /// active cooldown wins, otherwise a short forced-search shortcut window
    /// may open, otherwise both clear.
    private func applyDirectoryCommandCooldown(_ result: MangaDirectoryUpdateResult) {
        if let cooldownExpiresAt = result.cooldownExpiresAt {
            directoryCooldownExpiresAt = cooldownExpiresAt
            forcedSearchShortcutExpiresAt = nil
        } else if result.shouldOfferForcedSearch {
            directoryCooldownExpiresAt = nil
            forcedSearchShortcutExpiresAt = dependencies.directoryWorkflowConfiguration.now()
                .addingTimeInterval(dependencies.directoryWorkflowConfiguration.forcedSearchShortcutDuration)
        } else {
            directoryCooldownExpiresAt = nil
            forcedSearchShortcutExpiresAt = nil
        }
    }

    /// Applies a failed command's cooldown: a server-reported search
    /// cooldown wins, else whatever cooldown the workflow currently tracks.
    private func applyDirectoryFailureCooldown(_ error: Error, workflow: MangaReaderWorkflow) async {
        if case let YamiboError.searchCooldown(seconds) = error {
            directoryCooldownExpiresAt = dependencies.directoryWorkflowConfiguration.now()
                .addingTimeInterval(TimeInterval(seconds))
            forcedSearchShortcutExpiresAt = nil
        } else if let cooldown = await workflow.currentDirectorySearchCooldownExpiresAt() {
            directoryCooldownExpiresAt = cooldown
            forcedSearchShortcutExpiresAt = nil
        }
    }
}
