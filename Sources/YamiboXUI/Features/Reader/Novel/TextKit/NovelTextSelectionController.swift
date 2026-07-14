import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class NovelTextSelectionController {
    enum SelectionMode {
        case paged
        case vertical
    }

    enum HandleKind {
        case start
        case end
    }

    private let registeredViews = NSHashTable<NovelTextViewportReferenceUIView>.weakObjects()
    private var selectionRangeValue: NovelTextSelectionRange?
    private var baseAnchor: NovelTextSelectionAnchor?
    private var activeSurfaceIdentity: NovelReaderSurfaceIdentity?
    private weak var verticalScrollView: UIScrollView?
    private var mode = SelectionMode.paged
    private var likeWorkKey: LikeWorkKey?
    private var likeCaptureService: NovelTextLikeCaptureService?
    private var onLikeCaptured: ((LikeCaptureOutcome) -> Void)?

    var hasSelection: Bool {
        selectionRangeValue != nil
    }

    /// Whether the current selection resolves to a single-segment semantic
    /// position the Like capture service can anchor (A3: no chapter title ->
    /// no chapter identity -> nothing to anchor to).
    var canLike: Bool {
        likeWorkKey != nil && likeCaptureService != nil && likeAnchorEndpoints() != nil
    }

    func configure(mode: SelectionMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        if mode == .paged {
            verticalScrollView = nil
        }
        clearSelection()
    }

    func attachVerticalScrollView(_ scrollView: UIScrollView) {
        verticalScrollView = scrollView
    }

    func register(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.add(view)
        view.setNeedsDisplay()
    }

    func unregister(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.remove(view)
    }

    func beginSelection(
        in view: NovelTextViewportReferenceUIView,
        at point: CGPoint
    ) -> Bool {
        guard let displayReference = view.displayReference,
              !displayReference.isStale,
              let anchor = displayReference.selectionAnchor(at: point),
              let expandedRange = displayReference.expandedSelectionRange(around: anchor) else {
            clearSelection()
            return false
        }
        baseAnchor = anchor
        activeSurfaceIdentity = displayReference.surfaceIdentity
        selectionRangeValue = expandedRange
        refreshSelectionDisplay()
        return true
    }

    func updateSelection(
        in view: NovelTextViewportReferenceUIView,
        at point: CGPoint
    ) {
        guard let baseAnchor,
              let selectionTarget = selectionTarget(startingFrom: view, point: point),
              let displayReference = selectionTarget.view.displayReference,
              !displayReference.isStale else {
            return
        }
        if mode == .paged, displayReference.surfaceIdentity != activeSurfaceIdentity {
            return
        }
        guard let anchor = displayReference.selectionAnchor(at: selectionTarget.point),
              let range = displayReference.selectionRange(from: baseAnchor, to: anchor) else {
            return
        }
        selectionRangeValue = range
        autoScrollIfNeeded(from: selectionTarget.view, point: selectionTarget.point)
        refreshSelectionDisplay()
    }

    /// Seeds `baseAnchor` at the endpoint opposite the dragged handle, then
    /// dragging reuses `updateSelection(in:at:)` unchanged: it always builds
    /// the range between `baseAnchor` and the current touch point, and
    /// `selectionRange(from:to:)` normalizes the pair regardless of order.
    func beginHandleDrag(_ kind: HandleKind, generation: UInt64) -> Bool {
        guard let selectionRangeValue, selectionRangeValue.generation == generation else {
            return false
        }
        let fixedOffset = kind == .start ? selectionRangeValue.upperBound : selectionRangeValue.lowerBound
        baseAnchor = NovelTextSelectionAnchor(generation: generation, documentOffset: fixedOffset)
        return true
    }

    func clearSelection() {
        guard selectionRangeValue != nil || baseAnchor != nil else { return }
        selectionRangeValue = nil
        baseAnchor = nil
        activeSurfaceIdentity = nil
        dismissMenus()
        refreshSelectionDisplay()
    }

    func selectionRange(
        for displayReference: NovelTextViewportDisplayReference
    ) -> NovelTextSelectionRange? {
        guard let selectionRangeValue,
              selectionRangeValue.generation == displayReference.generation,
              !displayReference.isStale else {
            return nil
        }
        return selectionRangeValue
    }

    func menuTargetRect(in view: NovelTextViewportReferenceUIView) -> CGRect {
        guard let displayReference = view.displayReference,
              let range = selectionRange(for: displayReference) else {
            return view.bounds
        }
        let rects = displayReference.selectionRects(for: range)
        guard !rects.isEmpty else { return view.bounds }
        return rects.reduce(CGRect.null) { partial, rect in
            partial.union(rect)
        }
    }

    func selectedText() -> String? {
        guard let selectionRangeValue,
              let displayReference = firstCurrentDisplayReference(),
              let text = displayReference.selectedText(for: selectionRangeValue),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    func copySelection() {
        guard let text = selectedText() else { return }
        UIPasteboard.general.string = text
    }

    func configureLikeCapture(
        workKey: LikeWorkKey,
        service: NovelTextLikeCaptureService,
        onCaptured: @escaping (LikeCaptureOutcome) -> Void
    ) {
        likeWorkKey = workKey
        likeCaptureService = service
        onLikeCaptured = onCaptured
    }

    func likeSelection() {
        guard let likeWorkKey, let likeCaptureService,
              let endpoints = likeAnchorEndpoints() else {
            return
        }
        let request = NovelTextLikeCaptureRequest(
            workKey: likeWorkKey,
            start: endpoints.start,
            end: endpoints.end,
            excerptText: endpoints.excerptText,
            view: endpoints.documentView,
            resolvedAuthorID: endpoints.resolvedAuthorID
        )
        let onLikeCaptured = onLikeCaptured
        Task {
            guard let outcome = try? await likeCaptureService.like(request) else { return }
            onLikeCaptured?(outcome)
        }
    }

    func refreshSelectionDisplay() {
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }

    /// `registeredViews` commonly holds more than one live view at once
    /// (adjacent prefetched pages in paged mode, multiple visible surfaces in
    /// vertical mode), all sharing the same `generation` — it only changes on
    /// content reload, not per page. Matching on `generation` alone and
    /// taking the hash table's (unordered) first hit can resolve to a
    /// different on-screen surface than the one the selection actually lives
    /// on. `selectionRects`/`viewportSample` are per-surface windowed
    /// queries, so querying the wrong surface silently returns empty rects —
    /// this is why `canLike` used to fail even for an ordinary, single-
    /// segment selection. Prefer the exact surface the selection started on.
    private func firstCurrentDisplayReference() -> NovelTextViewportDisplayReference? {
        let candidates = registeredViews
            .allObjects
            .compactMap(\.displayReference)
            .filter { !$0.isStale && $0.generation == selectionRangeValue?.generation }
        if let activeSurfaceIdentity,
           let active = candidates.first(where: { $0.surfaceIdentity == activeSurfaceIdentity }) {
            return active
        }
        return candidates.first
    }

    /// There is no forwarding API that converts a raw document offset to a
    /// semantic position directly, only point-based ones (`viewportSample`).
    /// This recovers character-precise positions for both selection
    /// endpoints by hit-testing the exact rects `selectionRects(for:)`
    /// already computes for drawing the selection highlight.
    ///
    /// `documentView` comes straight off `start`'s `NovelTextViewportSample`
    /// — the exact forum page the selection's own surface is showing, not a
    /// coarser "reader's current page" signal. In vertical mode, several
    /// surfaces (adjacent pages) can be concurrently registered, so a
    /// same-generation, non-active surface can legitimately be on a
    /// different page than whatever the reader chrome currently reports as
    /// "visible" — using anything less precise here would reintroduce the
    /// same wrong-page bug `NovelTextLikeAnchor.view` exists to fix.
    private func likeAnchorEndpoints() -> (
        start: NovelTextViewportSemanticTextPosition,
        end: NovelTextViewportSemanticTextPosition,
        excerptText: String,
        documentView: Int,
        resolvedAuthorID: String?
    )? {
        guard let selectionRangeValue,
              let displayReference = firstCurrentDisplayReference(),
              let excerptText = displayReference.selectedText(for: selectionRangeValue),
              !excerptText.isEmpty else {
            return nil
        }
        let rects = displayReference.selectionRects(for: selectionRangeValue)
        guard let firstRect = rects.first, let lastRect = rects.last,
              let start = displayReference.viewportSample(
                  referencePoint: CGPoint(x: firstRect.minX + 1, y: firstRect.midY)
              ),
              let end = displayReference.viewportSample(
                  referencePoint: CGPoint(x: lastRect.maxX - 1, y: lastRect.midY)
              ),
              start.textSegmentIdentity == end.textSegmentIdentity,
              let chapterIdentity = start.textSegmentIdentity.chapterIdentity else {
            return nil
        }
        return (
            NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapterIdentity,
                textSegmentIdentity: start.textSegmentIdentity,
                displayedTextOffset: start.displayedTextOffset,
                progressInTextRange: 0
            ),
            NovelTextViewportSemanticTextPosition(
                chapterIdentity: chapterIdentity,
                textSegmentIdentity: end.textSegmentIdentity,
                displayedTextOffset: end.displayedTextOffset,
                progressInTextRange: 0
            ),
            excerptText,
            start.documentView,
            start.resolvedAuthorID
        )
    }

    private func selectionTarget(
        startingFrom view: NovelTextViewportReferenceUIView,
        point: CGPoint
    ) -> (view: NovelTextViewportReferenceUIView, point: CGPoint)? {
        guard mode == .vertical,
              let scrollView = verticalScrollView,
              view.window != nil else {
            return (view, point)
        }

        let pointInScrollView = view.convert(point, to: scrollView)
        let candidates = registeredViews.allObjects.filter {
            $0.window != nil && $0.displayReference?.isStale == false
        }
        if let containingView = candidates.first(where: { candidate in
            let candidatePoint = scrollView.convert(pointInScrollView, to: candidate)
            return candidate.point(inside: candidatePoint, with: nil)
        }) {
            return (
                containingView,
                scrollView.convert(pointInScrollView, to: containingView)
            )
        }

        guard let nearestView = candidates.min(by: { lhs, rhs in
            distance(from: pointInScrollView, to: lhs, in: scrollView) <
                distance(from: pointInScrollView, to: rhs, in: scrollView)
        }) else {
            return (view, point)
        }
        let nearestPoint = scrollView.convert(pointInScrollView, to: nearestView)
        return (
            nearestView,
            CGPoint(
                x: min(max(nearestPoint.x, nearestView.bounds.minX), nearestView.bounds.maxX),
                y: min(max(nearestPoint.y, nearestView.bounds.minY), nearestView.bounds.maxY)
            )
        )
    }

    private func distance(
        from point: CGPoint,
        to view: UIView,
        in scrollView: UIScrollView
    ) -> CGFloat {
        let frame = view.convert(view.bounds, to: scrollView)
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return hypot(dx, dy)
    }

    private func dismissMenus() {
        for view in registeredViews.allObjects {
            view.dismissCopyMenu()
        }
    }

    private func autoScrollIfNeeded(
        from view: UIView,
        point: CGPoint
    ) {
        guard mode == .vertical,
              let scrollView = verticalScrollView,
              view.window != nil else {
            return
        }
        let pointInScrollView = view.convert(point, to: scrollView)
        let edgeThreshold: CGFloat = 48
        let step: CGFloat = 18
        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )

        let nextOffsetY: CGFloat?
        if pointInScrollView.y < scrollView.bounds.minY + edgeThreshold {
            nextOffsetY = max(scrollView.contentOffset.y - step, minOffsetY)
        } else if pointInScrollView.y > scrollView.bounds.maxY - edgeThreshold {
            nextOffsetY = min(scrollView.contentOffset.y + step, maxOffsetY)
        } else {
            nextOffsetY = nil
        }

        guard let nextOffsetY,
              nextOffsetY != scrollView.contentOffset.y else {
            return
        }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: nextOffsetY),
            animated: false
        )
    }
}
#endif
