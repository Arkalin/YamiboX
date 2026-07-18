import Foundation
import YamiboXCore

/// Owns the manga reader's Like feature: the mode gating that decides
/// whether this reading session has a Like identity at all, page
/// like/unlike capture, and the `LikeStore` change observation that keeps
/// the liked-page markers fresh while a Like sheet (or another scene)
/// mutates the store. The `likedPageIDs` set itself stays a tracked
/// (observable) property on `MangaReaderViewModel` (written back through
/// `setLikedPageIDs`) because `MangaReaderView` observes only the view
/// model.
@MainActor
final class MangaReaderLikeModule {
    /// Reading context and state write-back supplied by the owning view model.
    struct Reading {
        var isSmartModeEnabled: Bool
        var forumID: String?
        var currentDirectoryCleanBookName: @MainActor () -> String?
        var makeLikeDependencies: @Sendable () -> LikeDependencies?
        var imageSource: @MainActor (MangaReaderPageProjection) -> YamiboImageSource
        var setLikedPageIDs: @MainActor (Set<String>) -> Void
    }

    private let reading: Reading
    private var likeChangeObservationTask: Task<Void, Never>?

    init(reading: Reading) {
        self.reading = reading
    }

    deinit {
        // The observation task rides the module's lifetime (it was moved
        // here from the view model together with the logic it serves).
        likeChangeObservationTask?.cancel()
    }

    private var likeWorkKey: LikeWorkKey? {
        // Smart Comic Mode off means this chapter is treated exactly like a normal thread
        // (see smart-comic-mode-design-decisions #2's 总原则) — the reader's directory in that
        // state is a synthesized single-chapter stand-in (MangaReaderWorkflow.standaloneDirectory),
        // not a real MangaDirectory, so it must not be usable as a manga-title Like identity.
        guard reading.isSmartModeEnabled else { return nil }
        guard let cleanBookName = reading.currentDirectoryCleanBookName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cleanBookName.isEmpty else {
            return nil
        }
        return .mangaTitle(cleanBookName: cleanBookName)
    }

    var canShowLikes: Bool {
        likeWorkKey != nil && reading.makeLikeDependencies() != nil
    }

    var likeSheetContext: (workKey: LikeWorkKey, like: LikeDependencies)? {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        return (workKey, like)
    }

    func likePage(_ page: MangaReaderPageProjection) async -> LikeCaptureOutcome? {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        let anchor = MangaImageLikeAnchor(chapterTID: page.tid, pageLocalIndex: page.localIndex, forumID: reading.forumID)
        let source = reading.imageSource(page)
        let service = MangaImageLikeCaptureService(likeStore: like.likeStore, likeImageStore: like.likeImageStore)
        let outcome = try? await service.like(
            workKey: workKey,
            anchor: anchor,
            sourceImageURL: source.url,
            imageData: { try await YamiboImagePipeline.shared.data(for: source) }
        )
        await refreshLikedPageIDs()
        return outcome
    }

    // Returns the existing Like Item for this page, if any, so the long-press
    // action sheet can offer "remove like" instead of "add to likes".
    func isPageLiked(_ page: MangaReaderPageProjection) async -> LikeItem? {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else { return nil }
        let items = await like.likeStore.likes(for: workKey)
        return items.first { item in
            guard case let .mangaImage(anchor) = item.anchor else { return false }
            return anchor.chapterTID == page.tid && anchor.pageLocalIndex == page.localIndex
        }
    }

    func unlikePage(_ item: LikeItem) async -> Bool {
        guard let like = reading.makeLikeDependencies() else { return false }
        do {
            // Terminal write: shield against the long-press confirmation dialog's
            // Task being cancelled mid-delete (e.g. the user closes the reader).
            try await Task {
                try await like.likeStore.delete(id: item.id)
                try await like.likeImageStore.delete(id: item.id)
            }.value
        } catch {
            return false
        }
        await refreshLikedPageIDs()
        return true
    }

    func refreshLikedPageIDs() async {
        guard let workKey = likeWorkKey, let like = reading.makeLikeDependencies() else {
            reading.setLikedPageIDs([])
            return
        }
        let items = await like.likeStore.likes(for: workKey)
        reading.setLikedPageIDs(Set(items.compactMap { item -> String? in
            guard case let .mangaImage(anchor) = item.anchor else { return nil }
            return "\(anchor.chapterTID)#\(anchor.pageLocalIndex)"
        }))
    }

    func observeLikeChangesIfNeeded() {
        guard likeChangeObservationTask == nil, let like = reading.makeLikeDependencies() else { return }
        let likeStore = like.likeStore
        let changeID = likeStore.changeID
        likeChangeObservationTask = Task { [weak self] in
            for await receivedChangeID in likeStore.changes() {
                // Per-instance stream: the guard is kept as the explicit
                // "only this exact store instance" contract.
                guard receivedChangeID == changeID else {
                    continue
                }
                await self?.refreshLikedPageIDs()
            }
        }
    }

    /// Reader-session teardown (retryInitialLoad): stop observing so the
    /// fresh session's `observeLikeChangesIfNeeded` can re-arm cleanly.
    func cancelObservation() {
        likeChangeObservationTask?.cancel()
        likeChangeObservationTask = nil
    }
}
