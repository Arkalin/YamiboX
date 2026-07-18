import YamiboXCore

#if os(iOS)
import UIKit

/// Renders persisted text Like Items as permanent highlights on top of the
/// same selection-rect geometry `NovelTextSelectionController` uses for the
/// live selection. Mirrors its register/unregister weak-view bookkeeping and
/// `LikeStore.changes()` changeID loop-filtering.
@MainActor
final class NovelLikeHighlightController {
    private let registeredViews = NSHashTable<NovelTextViewportReferenceUIView>.weakObjects()
    private var workKey: LikeWorkKey?
    private var likeStore: LikeStore?
    private var changeObserverTask: Task<Void, Never>?
    private var items: [LikeItem] = []
    private var rangesByItemID: [String: NovelTextSelectionRange] = [:]
    private var cachedGeneration: UInt64?

    deinit {
        changeObserverTask?.cancel()
    }

    func configure(workKey: LikeWorkKey, likeStore: LikeStore) {
        self.workKey = workKey
        self.likeStore = likeStore
        changeObserverTask?.cancel()
        let expectedChangeID = likeStore.changeID
        changeObserverTask = Task { @MainActor [weak self] in
            for await changeID in likeStore.changes() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Per-instance stream: the guard is kept as the explicit
                // "only this exact store instance" contract.
                guard changeID == expectedChangeID else {
                    continue
                }
                await self.reload()
            }
        }
        Task { await reload() }
    }

    func register(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.add(view)
        if let displayReference = view.displayReference {
            refreshIfNeeded(using: displayReference)
        }
        view.setNeedsDisplay()
    }

    func unregister(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.remove(view)
    }

    /// Every currently-resolvable highlight for `displayReference`'s surface,
    /// paired with the rects `selectionRects(for:)` already clips to that
    /// surface. Shared by the draw pass and tap hit-testing.
    func highlights(
        for displayReference: NovelTextViewportDisplayReference
    ) -> [(item: LikeItem, rects: [CGRect])] {
        refreshIfNeeded(using: displayReference)
        return rangesByItemID.compactMap { itemID, range -> (item: LikeItem, rects: [CGRect])? in
            guard let item = items.first(where: { $0.id == itemID }) else { return nil }
            let rects = displayReference.selectionRects(for: range)
            guard !rects.isEmpty else { return nil }
            return (item, rects)
        }
    }

    func item(at point: CGPoint, in view: NovelTextViewportReferenceUIView) -> LikeItem? {
        guard let displayReference = view.displayReference else { return nil }
        for entry in highlights(for: displayReference)
            where entry.rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return entry.item
        }
        return nil
    }

    func remove(_ item: LikeItem) async {
        try? await likeStore?.delete(id: item.id)
    }

    private func refreshIfNeeded(using displayReference: NovelTextViewportDisplayReference) {
        guard cachedGeneration != displayReference.generation else { return }
        cachedGeneration = displayReference.generation
        rangesByItemID.removeAll()
        for item in items {
            guard case let .novelText(anchor) = item.anchor,
                  let range = displayReference.highlightRange(
                      from: resumePoint(for: anchor, offset: anchor.range.location),
                      to: resumePoint(for: anchor, offset: anchor.range.upperBound)
                  ) else { continue }
            rangesByItemID[item.id] = range
        }
    }

    // `view: 1` is a placeholder: `documentSelectionRange` overrides it with
    // the active document's own `view` before lookup (see that method).
    private func resumePoint(for anchor: NovelTextLikeAnchor, offset: Int) -> NovelResumePoint {
        NovelResumePoint(
            view: 1,
            chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: anchor.textSegmentIdentity,
            displayedTextOffset: offset,
            chapterOrdinal: 0,
            segmentProgress: 0,
            readingModeHint: .paged
        )
    }

    private func reload() async {
        guard let workKey, let likeStore else { return }
        let fetched = await likeStore.likes(for: workKey)
        items = fetched.filter { $0.kind == .text }
        // Generation didn't change, so `refreshIfNeeded` won't recompute on
        // its own next call; force it and repaint every registered surface.
        cachedGeneration = nil
        rangesByItemID.removeAll()
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }
}
#endif
