import Foundation
import YamiboXCore

@MainActor
final class MangaReaderCoverModule {
    struct Reading {
        var isSmartModeEnabled: Bool
        var chapterTID: String
        var displayTitle: String
        var currentDirectoryID: @MainActor () -> MangaDirectoryID?
        var makeContentCoverStore: @Sendable () -> ContentCoverStore?
        var makeThreadCoverPageRepository: @Sendable () async -> (any ThreadCoverPageResolving)?
        var imageSource: @MainActor (MangaReaderPageProjection) -> YamiboImageSource
        var isReaderLoaded: @MainActor () -> Bool
    }

    private let reading: Reading
    private(set) var failureDetails: LoadFailureDetails?
    private(set) var actionWasCancelled = false
    private var autoThreadCoverResolutionTask: Task<Void, Never>?

    init(reading: Reading) {
        self.reading = reading
    }

    deinit {
        autoThreadCoverResolutionTask?.cancel()
    }

    private var mangaCoverKey: ContentCoverKey? {
        guard reading.isSmartModeEnabled else {
            return .thread(tid: reading.chapterTID)
        }
        guard let id = reading.currentDirectoryID() else { return nil }
        return .smartManga(directoryID: id)
    }

    var canSetMangaCover: Bool {
        mangaCoverKey != nil && reading.makeContentCoverStore() != nil
    }

    func hasManualMangaCover() async -> Bool {
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        return await store.cover(for: key)?.manualCoverURL != nil
    }

    func setMangaCover(page: MangaReaderPageProjection) async -> Bool {
        failureDetails = nil
        actionWasCancelled = false
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        do {
            try await store.setManualCover(reading.imageSource(page), for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to set manual manga cover: \(error.localizedDescription)")
            actionWasCancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
            if !actionWasCancelled { failureDetails = LoadFailureDetails(error: error) }
            return false
        }
    }

    func restoreAutomaticMangaCover() async -> Bool {
        failureDetails = nil
        actionWasCancelled = false
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        do {
            try await store.clearManualCover(for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to clear manual manga cover: \(error.localizedDescription)")
            actionWasCancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
            if !actionWasCancelled { failureDetails = LoadFailureDetails(error: error) }
            return false
        }
    }

    func startAutoThreadCoverResolutionIfNeeded() {
        guard !reading.isSmartModeEnabled,
              reading.isReaderLoaded(),
              autoThreadCoverResolutionTask == nil else {
            return
        }
        autoThreadCoverResolutionTask = Task { @MainActor [weak self] in
            await self?.performAutoThreadCoverResolution()
        }
    }

    func cancelAutoThreadCoverResolution() {
        autoThreadCoverResolutionTask?.cancel()
        autoThreadCoverResolutionTask = nil
    }

    private func performAutoThreadCoverResolution() async {
        defer { autoThreadCoverResolutionTask = nil }
        guard let coverStore = reading.makeContentCoverStore(),
              let repository = await reading.makeThreadCoverPageRepository() else {
            return
        }
        let tid = reading.chapterTID
        guard let coverCandidate = await ThreadCoverResolver().resolve(
            thread: ThreadIdentity(tid: tid),
            title: reading.displayTitle,
            repository: repository
        ) else {
            return
        }
        do {
            _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: tid))
        } catch {
            YamiboLog.library.error("Failed to set automatic cover for manga chapter thread \(tid) while Smart Comic Mode is off: \(error.localizedDescription)")
        }
    }
}
