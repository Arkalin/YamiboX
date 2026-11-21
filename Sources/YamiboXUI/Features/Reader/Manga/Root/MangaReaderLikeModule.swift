import Foundation
import YamiboXCore

@MainActor
final class MangaReaderLikeModule {
    struct Reading {
        var isSmartModeEnabled: Bool
        var forumID: String?
        var currentDirectoryID: @MainActor () -> MangaDirectoryID?
        var makeLikeDependencies: @Sendable () -> LikeDependencies?
        var imageData: @Sendable (YamiboImageSource) async throws -> Data
        var imageSource: @MainActor (MangaReaderPageProjection) -> YamiboImageSource
        var setLikedPageIDs: @MainActor (Set<String>) -> Void
        var onFailure: @MainActor (any Error) -> Void
    }

    private let reading: Reading
    private(set) var failureDetails: LoadFailureDetails?
    private(set) var actionWasCancelled = false
    private var likeChangeObservationTask: Task<Void, Never>?
    private var observationGeneration = 0

    init(reading: Reading) {
        self.reading = reading
    }

    deinit {
        likeChangeObservationTask?.cancel()
    }

    private var likeWorkKey: ReadingWorkKey? {
        guard reading.isSmartModeEnabled else { return nil }
        guard let id = reading.currentDirectoryID() else { return nil }
        return .mangaTitle(directoryID: id)
    }

    var canShowLikes: Bool {
        likeWorkKey != nil && reading.makeLikeDependencies() != nil
    }

    var likeSheetContext: (workKey: ReadingWorkKey, like: LikeDependencies)? {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        return (workKey, like)
    }

    func likePage(_ page: MangaReaderPageProjection) async -> LikeCaptureOutcome? {
        failureDetails = nil
        actionWasCancelled = false
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        let anchor = MangaImageLikeAnchor(chapterTID: page.tid, pageLocalIndex: page.localIndex, forumID: reading.forumID)
        let source = reading.imageSource(page)
        let service = MangaImageLikeCaptureService(likeStore: like.likeStore, likeImageStore: like.likeImageStore)
        let outcome: LikeCaptureOutcome?
        do {
            outcome = try await service.like(
            workKey: workKey,
            anchor: anchor,
            sourceImageURL: source.url,
            chapterTitle: page.chapterTitle,
            imageData: { [imageData = reading.imageData] in try await imageData(source) }
            )
        } catch {
            actionWasCancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
            if !actionWasCancelled { failureDetails = LoadFailureDetails(error: error) }
            outcome = nil
        }
        await refreshLikedPageIDs()
        return outcome
    }

    func isPageLiked(_ page: MangaReaderPageProjection) async throws -> LikeItem? {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        let items = try await like.likeStore.likes(for: workKey)
        return items.first { item in
            guard case let .mangaImage(anchor) = item.anchor else { return false }
            return anchor.chapterTID == page.tid && anchor.pageLocalIndex == page.localIndex
        }
    }

    func unlikePage(_ item: LikeItem) async -> Bool {
        failureDetails = nil
        actionWasCancelled = false
        guard let like = reading.makeLikeDependencies() else { return false }
        do {
            try await like.annotations.removeLikes([item])
        } catch {
            actionWasCancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
            if !actionWasCancelled { failureDetails = LoadFailureDetails(error: error) }
            return false
        }
        await refreshLikedPageIDs()
        return true
    }

    func refreshLikedPageIDs() async {
        guard !Task.isCancelled else { return }
        let generation = observationGeneration
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else {
            reading.setLikedPageIDs([])
            return
        }
        let items: [LikeItem]
        do { items = try await like.likeStore.likes(for: workKey) }
        catch {
            if !Task.isCancelled, observationGeneration == generation,
               !LoadDiagnosticError.isCancellation(error) {
                reading.onFailure(error)
            }
            return
        }
        guard !Task.isCancelled, observationGeneration == generation, likeWorkKey == workKey else { return }
        _ = await like.resolveChapterInfo(for: items, work: workKey)
        guard !Task.isCancelled, observationGeneration == generation, likeWorkKey == workKey else { return }
        reading.setLikedPageIDs(Set(items.compactMap { item -> String? in
            guard case let .mangaImage(anchor) = item.anchor else { return nil }
            return "\(anchor.chapterTID)#\(anchor.pageLocalIndex)"
        }))
    }

    func observeLikeChangesIfNeeded() {
        guard likeChangeObservationTask == nil, let like = reading.makeLikeDependencies() else { return }
        let likeStore = like.likeStore
        likeChangeObservationTask = Task { [weak self] in
            for await _ in likeStore.changes() {
                guard !Task.isCancelled else { return }
                await self?.refreshLikedPageIDs()
            }
        }
    }

    func cancelObservation() {
        observationGeneration += 1
        likeChangeObservationTask?.cancel()
        likeChangeObservationTask = nil
    }
}
