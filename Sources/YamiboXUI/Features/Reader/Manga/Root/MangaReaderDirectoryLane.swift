import Foundation
import YamiboXCore

// MARK: - Directory management
//
// The reader's directory command lane: panel-driven update/search, reset,
// rename, chapter deletion, the automatic post-load update, and the
// cooldown/forced-search countdown that the directory panel renders. The
// lane's outputs ARE reader content — every mutation republishes through
// the view model's `publishPresentation` — so the lane does not touch
// presentation directly; it reaches reader content only through the
// `Reader` closures the view model supplies. What it owns outright is the
// command serialization state: the mutation/tick/auto-update task handles,
// the mutation generation, and the cooldown deadlines.
@MainActor
final class MangaReaderDirectoryLane {
    /// Reader-content access supplied by the owning view model. Directory
    /// mutations republish full reader content, which stays a view-model
    /// concern (generations, browsing-history sync, progress scheduling).
    struct Reader {
        var workflow: @MainActor () -> MangaReaderWorkflow?
        var presentation: @MainActor () -> MangaReaderPresentation
        /// Direct presentation write for panel command state (updating
        /// flag, countdowns, error text) — deliberately NOT
        /// `publishPresentation`: command state is panel chrome, not reader
        /// content, so it must not re-trigger browsing-history or progress
        /// side effects.
        var setPresentation: @MainActor (MangaReaderPresentation) -> Void
        var progressSnapshot: @MainActor (MangaReaderPresentation) -> MangaReaderProgressSnapshot?
        var publishPresentation: @MainActor (MangaReaderPresentation, MangaReaderProgressSnapshot?) -> Void
        var invalidateReaderContent: @MainActor () -> Void
        var offlineCacheOwnerName: @MainActor () -> String?
    }

    private let dependencies: MangaReaderViewModelDependencies
    private let reader: Reader

    private var directoryCooldownExpiresAt: Date?
    private var forcedSearchShortcutExpiresAt: Date?
    private var directoryTickTask: Task<Void, Never>?
    private var directoryMutationTask: Task<Void, Never>?
    private var automaticDirectoryUpdateTask: Task<Void, Never>?
    private var directoryMutationGeneration = 0

    init(dependencies: MangaReaderViewModelDependencies, reader: Reader) {
        self.dependencies = dependencies
        self.reader = reader
    }

    deinit {
        // The lane's task handles ride its lifetime (they were moved here
        // from the view model together with the command logic they serve).
        directoryTickTask?.cancel()
        directoryMutationTask?.cancel()
        automaticDirectoryUpdateTask?.cancel()
    }

    // MARK: - Commands

    func updateDirectoryFromPanel() async {
        guard case let .loaded(loaded) = reader.presentation().state else { return }
        await updateDirectory(isForcedSearch: loaded.directoryPanel.shouldForceSearchOnUpdate)
    }

    func updateDirectory(isForcedSearch: Bool = false) async {
        if isForcedSearch {
            automaticDirectoryUpdateTask?.cancel()
            automaticDirectoryUpdateTask = nil
        }
        await enqueueDirectoryUpdate(isForcedSearch: isForcedSearch, isAutomatic: false)
    }

    func resetDirectory() async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        reader.invalidateReaderContent()
        directoryMutationGeneration += 1
        let generation = directoryMutationGeneration
        directoryMutationTask = Task { @MainActor [weak self] in
            await self?.performDirectoryReset(mutationGeneration: generation)
        }
        await directoryMutationTask?.value
    }

    func renameDirectory(cleanBookName: String, searchKeyword: String) async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        reader.invalidateReaderContent()
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

    func renameDirectory(with draft: MangaDirectoryEditDraft) async {
        await renameDirectory(
            cleanBookName: draft.cleanBookName,
            searchKeyword: MangaDirectoryWorkflow.searchKeyword(from: draft)
        )
    }

    func deleteDirectoryChapters(tids: Set<String>) async {
        guard case let .loaded(loaded) = reader.presentation().state else { return }
        let targetTIDs = Set(tids.compactMap(MangaReaderViewModel.normalizedNonEmpty))
        guard !targetTIDs.isEmpty else { return }
        if let currentChapterTID = loaded.directoryPanel.currentChapterTID,
           targetTIDs.contains(currentChapterTID) {
            return
        }

        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        directoryMutationTask?.cancel()
        reader.invalidateReaderContent()
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

    /// Reader-session teardown (retryInitialLoad): drop the transient
    /// cooldown deadlines so the fresh session starts with a clean panel.
    func resetCooldownState() {
        directoryCooldownExpiresAt = nil
        forcedSearchShortcutExpiresAt = nil
    }

    /// Reader-session teardown (retryInitialLoad): stop every in-flight
    /// lane task; the fresh session schedules its own.
    func cancelTasks() {
        directoryTickTask?.cancel()
        directoryTickTask = nil
        directoryMutationTask?.cancel()
        directoryMutationTask = nil
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
    }

    private func enqueueDirectoryUpdate(isForcedSearch: Bool, isAutomatic: Bool) async {
        if isAutomatic, directoryMutationTask != nil {
            automaticDirectoryUpdateTask = nil
            return
        }

        if !isAutomatic {
            directoryMutationTask?.cancel()
        }

        reader.invalidateReaderContent()
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
        guard let workflow = reader.workflow() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(reader.presentation())

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
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
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
        guard let workflow = reader.workflow() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(reader.presentation())

        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let result = try await workflow.resetDirectory()
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
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
        guard let workflow = reader.workflow() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(reader.presentation())
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let oldOwnerName = reader.offlineCacheOwnerName()
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
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
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
        guard let workflow = reader.workflow() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(reader.presentation())
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let nextPresentation = try await workflow.deleteDirectoryChapters(tids: tids)
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration else { return }
            reader.publishPresentation(nextPresentation, previousProgressSnapshot)
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

    // MARK: - Panel command state and countdowns

    var currentDirectoryPanelErrorMessage: String? {
        guard case let .loaded(loaded) = reader.presentation().state else { return nil }
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
        guard let workflow = reader.workflow() else { return }
        let now = dependencies.directoryWorkflowConfiguration.now()
        let cooldownRemaining = remainingSecondsValue(until: directoryCooldownExpiresAt, now: now)
        let forcedRemaining = remainingSeconds(until: forcedSearchShortcutExpiresAt, now: now)
        if cooldownRemaining == 0 {
            directoryCooldownExpiresAt = nil
        }
        if forcedRemaining == nil {
            forcedSearchShortcutExpiresAt = nil
        }
        reader.setPresentation(workflow.updateDirectoryPanelCommandState(
            MangaDirectoryPanelCommandState(
                isUpdating: isUpdating,
                cooldownRemaining: cooldownRemaining,
                forcedSearchShortcutRemaining: forcedRemaining,
                errorMessage: errorMessage
            )
        ))
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

// MARK: - View-model command surface
//
// Thin forwarders so `MangaDirectorySheet`'s closures and the tests keep
// calling `model.updateDirectory(...)` etc. unchanged; the lane is the
// implementation.
extension MangaReaderViewModel {

    public func updateDirectoryFromPanel() async {
        await directoryLane.updateDirectoryFromPanel()
    }

    public func updateDirectory(isForcedSearch: Bool = false) async {
        await directoryLane.updateDirectory(isForcedSearch: isForcedSearch)
    }

    public func resetDirectory() async {
        await directoryLane.resetDirectory()
    }

    public func renameDirectory(cleanBookName: String, searchKeyword: String) async {
        await directoryLane.renameDirectory(cleanBookName: cleanBookName, searchKeyword: searchKeyword)
    }

    public func renameDirectory(with draft: MangaDirectoryEditDraft) async {
        await directoryLane.renameDirectory(with: draft)
    }

    public func deleteDirectoryChapters(tids: Set<String>) async {
        await directoryLane.deleteDirectoryChapters(tids: tids)
    }
}
