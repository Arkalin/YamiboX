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

    /// One annotation resolved onto a concrete surface.
    struct ResolvedHighlight {
        let item: LikeItem
        /// Already clipped to this surface by `selectionRects(for:)`.
        let rects: [CGRect]
        /// Rect of the annotation's FIRST character, and only when that
        /// character is on THIS surface — the note badge pins to the
        /// highlight's beginning, Apple Books style. `rects.first` is merely
        /// the start of the visible portion here, so it would put the badge at
        /// the page break of an annotation that started overleaf.
        let startRect: CGRect?
    }

    /// Every currently-resolvable highlight for `displayReference`'s surface.
    /// Shared by the draw pass and tap hit-testing.
    ///
    /// Sorted by document position: `rangesByItemID` is a Dictionary, and an
    /// unordered draw order made no visible difference while every highlight
    /// was the same yellow — with six colours it would z-fight between frames
    /// wherever two annotations touch.
    func highlights(
        for displayReference: NovelTextViewportDisplayReference
    ) -> [ResolvedHighlight] {
        refreshIfNeeded(using: displayReference)
        return rangesByItemID
            .compactMap { itemID, range -> (range: NovelTextSelectionRange, resolved: ResolvedHighlight)? in
                guard let item = items.first(where: { $0.id == itemID }) else { return nil }
                let rects = displayReference.selectionRects(for: range)
                guard !rects.isEmpty else { return nil }
                return (range, ResolvedHighlight(
                    item: item,
                    rects: rects,
                    startRect: startRect(of: range, in: displayReference)
                ))
            }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map(\.resolved)
    }

    /// Probes a synthetic one-character range at the annotation's first
    /// character; an empty result means that character lives on another
    /// surface.
    private func startRect(
        of range: NovelTextSelectionRange,
        in displayReference: NovelTextViewportDisplayReference
    ) -> CGRect? {
        guard let firstCharacter = NovelTextSelectionRange(
            generation: range.generation,
            lowerBound: range.lowerBound,
            upperBound: range.lowerBound + 1
        ) else {
            return nil
        }
        return displayReference.selectionRects(for: firstCharacter).first
    }

    func item(at point: CGPoint, in view: NovelTextViewportReferenceUIView) -> LikeItem? {
        guard let displayReference = view.displayReference else { return nil }
        for entry in highlights(for: displayReference)
            where entry.rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return entry.item
        }
        return nil
    }

    /// Union of the rects `item` occupies on `view`'s surface, for anchoring
    /// the style capsule. Empty when the item isn't resolvable there.
    func unionRect(for item: LikeItem, in view: NovelTextViewportReferenceUIView) -> CGRect? {
        guard let displayReference = view.displayReference else { return nil }
        let rects = highlights(for: displayReference)
            .first { $0.item.id == item.id }?
            .rects ?? []
        guard !rects.isEmpty else { return nil }
        return rects.reduce(CGRect.null) { $0.union($1) }
    }

    func remove(_ item: LikeItem) async {
        try? await likeStore?.delete(id: item.id)
    }

    func updateStyle(_ item: LikeItem, to style: LikeStyle) async {
        _ = try? await likeStore?.updateStyle(id: item.id, style: style)
    }

    /// Repaints a style change on the same runloop tick as the tap, for the
    /// same reason `applyCapturedItem` exists: the store-change round trip
    /// lands a frame or more later, which would make the colour lag the touch.
    /// The eventual `reload()` reconciles.
    func applyStyleOptimistically(itemID: String, style: LikeStyle) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].style = style
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }

    /// Optimistically paints a just-captured like on the same runloop tick as
    /// its success haptic — the store-change notification round trip that
    /// `reload()` waits on lands a frame or more later, which decouples the
    /// visual from the haptic. The eventual `reload()` reconciles.
    func applyCapturedItem(_ item: LikeItem) {
        guard item.kind == .text else { return }
        items.removeAll { $0.id == item.id }
        items.append(item)
        cachedGeneration = nil
        rangesByItemID.removeAll()
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }

    private func refreshIfNeeded(using displayReference: NovelTextViewportDisplayReference) {
        guard cachedGeneration != displayReference.generation else { return }
        cachedGeneration = displayReference.generation
        rangesByItemID.removeAll()
        for item in items {
            // Each endpoint resolves through its OWN segment identity, which
            // is what lets one annotation span the illustration that split its
            // text into two segments.
            guard case let .novelText(anchor) = item.anchor,
                  let range = displayReference.highlightRange(
                      from: resumePoint(for: anchor, endpoint: anchor.start),
                      to: resumePoint(for: anchor, endpoint: anchor.end)
                  ) else { continue }
            rangesByItemID[item.id] = range
        }
        backfillExcerptContexts(using: displayReference)
    }

    /// Heals the clause context of annotations that predate the field (or
    /// arrived over WebDAV, which never carries it): this is the first moment
    /// a device is guaranteed to hold both the item and the laid-out chapter
    /// text it was captured from. One-shot per item — a healed item has
    /// non-nil context and is never sliced again.
    private func backfillExcerptContexts(using displayReference: NovelTextViewportDisplayReference) {
        guard let likeStore else { return }
        var contexts: [String: (prefix: String?, suffix: String?)] = [:]
        for item in items where item.excerptPrefix == nil && item.excerptSuffix == nil {
            guard let range = rangesByItemID[item.id],
                  let surrounding = displayReference.surroundingText(for: range, radius: 80) else {
                continue
            }
            contexts[item.id] = NovelLikeExcerptContext.make(
                textBefore: surrounding.before,
                textAfter: surrounding.after
            )
        }
        guard !contexts.isEmpty else { return }
        // The store skips no-op rows and only notifies when something actually
        // changed, so a context that legitimately resolves to (nil, nil) can't
        // loop the observers.
        Task { await likeStore.resolveExcerptContexts(contexts) }
    }

    // `view: 1` is a placeholder: `documentSelectionRange` overrides it with
    // the active document's own `view` before lookup (see that method).
    private func resumePoint(for anchor: NovelTextLikeAnchor, endpoint: NovelLikeTextEndpoint) -> NovelResumePoint {
        NovelResumePoint(
            view: 1,
            chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: endpoint.segmentIdentity),
            displayedTextOffset: endpoint.offset,
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
