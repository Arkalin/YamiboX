import Foundation
import YamiboXCore

@MainActor
final class MangaReaderDirectoryLane {
    struct Reader {
        var workflow: @MainActor () -> MangaReaderWorkflow?
        var presentation: @MainActor () -> MangaReaderPresentation?
        var setPresentation: @MainActor (MangaReaderPresentation) -> Void
        var progressSnapshot: @MainActor (MangaReaderPresentation) -> MangaReaderProgressSnapshot?
        var publishPresentation: @MainActor (MangaReaderPresentation, MangaReaderProgressSnapshot?) -> Void
        var downloadOwnerName: @MainActor () -> String?
    }

    private let dependencies: MangaReaderViewModelDependencies
    private let reader: Reader

    private var directoryTiming = MangaDirectoryCommandTiming()
    private var directoryTickTask: Task<Void, Never>?
    private var directoryMutationTask: Task<Void, Never>?
    private var automaticDirectoryUpdateTask: Task<Void, Never>?
    private var directoryMutationGeneration = 0

    init(dependencies: MangaReaderViewModelDependencies, reader: Reader) {
        self.dependencies = dependencies
        self.reader = reader
    }

    deinit {
        directoryTickTask?.cancel()
        directoryMutationTask?.cancel()
        automaticDirectoryUpdateTask?.cancel()
    }


    func updateDirectoryFromPanel() async {
        guard case let .loaded(loaded) = reader.presentation()?.state else { return }
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
        let generation = beginDirectoryMutation(cancellingExistingTask: true)
        directoryMutationTask = Task { @MainActor [weak self] in
            await self?.performDirectoryReset(mutationGeneration: generation)
        }
        await directoryMutationTask?.value
    }

    func renameDirectory(cleanBookName: String, searchKeyword: String) async {
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        let generation = beginDirectoryMutation(cancellingExistingTask: true)
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
            searchKeyword: MangaDirectoryLocalEditor.searchKeyword(from: draft)
        )
    }

    func deleteDirectoryChapters(tids: Set<String>) async {
        guard case let .loaded(loaded) = reader.presentation()?.state else { return }
        let targetTIDs = Set(tids.compactMap { $0.nilIfBlank })
        guard !targetTIDs.isEmpty else { return }
        if let currentChapterTID = loaded.directoryPanel.currentChapterTID,
           targetTIDs.contains(currentChapterTID) {
            return
        }

        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        let generation = beginDirectoryMutation(cancellingExistingTask: true)
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

    func resetCooldownState() {
        directoryTiming = MangaDirectoryCommandTiming()
    }

    func cancelTasks() {
        directoryMutationGeneration += 1
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

        let generation = beginDirectoryMutation(cancellingExistingTask: !isAutomatic)
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

    private func beginDirectoryMutation(cancellingExistingTask: Bool) -> Int {
        if cancellingExistingTask {
            directoryMutationTask?.cancel()
        }
        directoryMutationGeneration += 1
        return directoryMutationGeneration
    }

    private func performDirectoryUpdate(
        isForcedSearch: Bool,
        isAutomatic: Bool,
        mutationGeneration: Int
    ) async {
        guard let workflow = reader.workflow(), let presentation = reader.presentation() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(presentation)

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
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
            applyDirectoryCommandCooldown(result)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            YamiboLog.reader.error("Manga directory update failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            if !LoadDiagnosticError.isCancellation(error) {
                refreshDirectoryPanelTiming(errorMessage: error.localizedDescription, details: LoadFailureDetails(error: error))
            }
        }
    }

    private func performDirectoryReset(mutationGeneration: Int) async {
        guard let workflow = reader.workflow(), let presentation = reader.presentation() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(presentation)

        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let result = try await workflow.resetDirectory()
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
            applyDirectoryCommandCooldown(result)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            YamiboLog.reader.error("Manga directory reset failed: \(error.localizedDescription)")
            await applyDirectoryFailureCooldown(error, workflow: workflow)
            if !LoadDiagnosticError.isCancellation(error) {
                refreshDirectoryPanelTiming(errorMessage: error.localizedDescription, details: LoadFailureDetails(error: error))
            }
        }
    }

    private func performRenameDirectory(
        cleanBookName: String,
        searchKeyword: String,
        mutationGeneration: Int
    ) async {
        guard let workflow = reader.workflow(), let presentation = reader.presentation() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(presentation)
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            _ = try await workflow.renameDirectory(cleanBookName: cleanBookName, searchKeyword: searchKeyword)
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            reader.publishPresentation(workflow.presentation, previousProgressSnapshot)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            YamiboLog.reader.error("Manga directory rename failed: \(error.localizedDescription)")
            if !LoadDiagnosticError.isCancellation(error) {
                refreshDirectoryPanelTiming(errorMessage: error.localizedDescription, details: LoadFailureDetails(error: error))
            }
        }
    }

    private func performDeleteDirectoryChapters(
        tids: Set<String>,
        mutationGeneration: Int
    ) async {
        guard let workflow = reader.workflow(), let presentation = reader.presentation() else { return }
        let previousProgressSnapshot = reader.progressSnapshot(presentation)
        defer {
            if directoryMutationGeneration == mutationGeneration {
                directoryMutationTask = nil
            }
        }

        setDirectoryPanelCommandState(isUpdating: true, errorMessage: nil)
        do {
            let nextPresentation = try await workflow.deleteDirectoryChapters(tids: tids)
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            reader.publishPresentation(nextPresentation, previousProgressSnapshot)
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            guard directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
        } catch {
            guard !Task.isCancelled, directoryMutationGeneration == mutationGeneration, reader.presentation() != nil else { return }
            YamiboLog.reader.error("Deleting manga directory chapters failed: \(error.localizedDescription)")
            if !LoadDiagnosticError.isCancellation(error) {
                refreshDirectoryPanelTiming(errorMessage: error.localizedDescription, details: LoadFailureDetails(error: error))
            }
        }
    }


    var currentDirectoryPanelErrorMessage: String? {
        guard case let .loaded(loaded) = reader.presentation()?.state else { return nil }
        return loaded.directoryPanel.errorMessage
    }

    private var directoryErrorDetails: LoadFailureDetails?
    private var directoryFailureEventID: UUID?

    func refreshDirectoryPanelTiming(errorMessage: String?, details: LoadFailureDetails? = nil) {
        if let details {
            directoryErrorDetails = details
            directoryFailureEventID = UUID()
        }
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
        if errorMessage == nil {
            directoryErrorDetails = nil
            directoryFailureEventID = nil
        }
        let timing = directoryTiming.refresh(at: dependencies.directoryWorkflowConfiguration.now())
        reader.setPresentation(workflow.updateDirectoryPanelCommandState(
            MangaDirectoryPanelCommandState(
                isUpdating: isUpdating,
                cooldownRemaining: timing.cooldownRemaining,
                forcedSearchShortcutRemaining: timing.forcedSearchShortcutRemaining,
                errorMessage: errorMessage,
                errorDetails: directoryErrorDetails,
                failureEventID: directoryFailureEventID
            )
        ))
    }

    private func updateDirectoryTickTask() {
        guard directoryTiming.hasActiveDeadline else {
            directoryTickTask?.cancel()
            directoryTickTask = nil
            return
        }
        guard directoryTickTask == nil else { return }

        directoryTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.reader.presentation() != nil else {
                    self?.directoryTickTask = nil
                    return
                }
                self?.setDirectoryPanelCommandState(
                    isUpdating: false,
                    errorMessage: self?.currentDirectoryPanelErrorMessage
                )
                guard self?.directoryTiming.hasActiveDeadline == true else {
                    self?.directoryTickTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func applyDirectoryCommandCooldown(_ result: MangaDirectoryUpdateResult) {
        directoryTiming.apply(result, configuration: dependencies.directoryWorkflowConfiguration)
    }

    private func applyDirectoryFailureCooldown(_ error: Error, workflow: MangaReaderWorkflow) async {
        let deadline = await MangaDirectoryCommandTiming.failureCooldownExpiresAt(
            for: error,
            now: dependencies.directoryWorkflowConfiguration.now,
            fallback: { await workflow.currentDirectorySearchCooldownExpiresAt() }
        )
        directoryTiming.applyCooldown(until: deadline)
    }
}

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
