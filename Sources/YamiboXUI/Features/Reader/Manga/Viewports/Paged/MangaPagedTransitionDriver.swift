#if os(iOS)
import UIKit

@MainActor
final class MangaPagedTransitionDriver {
    enum Effect {
        case cut
        case slide
        case quickFade
    }

    enum Event {
        case landed
        case finished
        case cancelled
    }

    private var slide: ReaderPagedSlideAnimation?
    private var slideID: UUID?
    private var restingItem: Int?
    private var fadeSnapshot: UIView?
    private var baseColor: UIColor = .black

    func updateBaseColor(_ color: UIColor, in collection: UICollectionView) {
        guard baseColor != color || collection.backgroundColor == nil else { return }
        baseColor = color
        if restingItem == nil { collection.backgroundColor = color }
        else { updateSlideVisuals(in: collection) }
    }

    func start(
        id: UUID,
        effect: Effect,
        sourceItem: Int,
        offsetX: CGFloat,
        in collection: UICollectionView,
        report: @escaping (UUID, Event) -> Void
    ) {
        let target = CGPoint(x: offsetX, y: collection.contentOffset.y)
        if effect == .slide {
            removeFade()
            if abs(collection.contentOffset.x - target.x) > 0.5 / max(collection.traitCollection.displayScale, 1) {
                slideID = id
                beginSlideVisuals(from: sourceItem, in: collection)
                slide = ReaderPagedSlideAnimation(in: collection, targetOffset: target) {
                    [weak self, weak collection] completed in
                    guard let self, let collection, self.slideID == id else { return }
                    self.slide = nil
                    self.slideID = nil
                    self.endSlideVisuals(in: collection)
                    if completed { report(id, .landed) }
                    report(id, completed ? .finished : .cancelled)
                }
                return
            }
        }

        var newSnapshot: UIView?
        if effect == .quickFade, fadeSnapshot == nil, let container = collection.superview,
           let snapshot = collection.snapshotView(afterScreenUpdates: false) {
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            snapshot.frame = collection.convert(collection.bounds, to: container)
            container.addSubview(snapshot)
            fadeSnapshot = snapshot
            newSnapshot = snapshot
        }
        collection.setContentOffset(target, animated: false)
        collection.layoutIfNeeded()
        report(id, .landed)
        guard let snapshot = newSnapshot else {
            report(id, .finished)
            return
        }
        UIView.animate(
            withDuration: ReaderPagedQuickFadeTransition.duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            snapshot.alpha = 0
        } completion: { [weak self] finished in
            guard self?.fadeSnapshot === snapshot else { return }
            self?.removeFade()
            report(id, finished ? .finished : .cancelled)
        }
    }

    func cancel(in collection: UICollectionView) {
        slide?.cancel()
        slide = nil
        slideID = nil
        endSlideVisuals(in: collection)
        removeFade()
    }

    func beginSlideVisuals(from item: Int, in collection: UICollectionView) {
        restingItem = item
        updateSlideVisuals(in: collection)
    }

    func updateSlideVisuals(in collection: UICollectionView) {
        guard let restingItem else { return }
        let metrics = ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: collection.contentOffset.x,
            pageWidth: collection.bounds.width,
            pageCount: collection.numberOfItems(inSection: 0),
            restingPageIndex: restingItem,
            cornerRadius: ReaderPagedPageTurnCornerRadius.radius(for: collection.window?.screen)
        )
        collection.backgroundColor = metrics.map {
            ReaderPagedPageTurnBackground.dimmedPageColor(baseColor: baseColor, overlayAlpha: $0.overlayAlpha)
        } ?? baseColor
        for case let cell as ReaderPagedPageTurnCell in collection.visibleCells {
            let item = collection.indexPath(for: cell)?.item
            if let metrics, item == metrics.maskedPageIndex {
                cell.applyPageTurnVisuals(overlayAlpha: metrics.overlayAlpha, cornerRadius: 0)
            } else if let metrics, item == metrics.roundedPageIndex {
                cell.applyPageTurnVisuals(overlayAlpha: 0, cornerRadius: metrics.cornerRadius)
            } else {
                cell.resetPageTurnVisuals()
            }
        }
    }

    func endSlideVisuals(in collection: UICollectionView) {
        guard restingItem != nil else { return }
        restingItem = nil
        collection.backgroundColor = baseColor
        for case let cell as ReaderPagedPageTurnCell in collection.visibleCells {
            cell.resetPageTurnVisuals()
        }
    }

    private func removeFade() {
        let snapshot = fadeSnapshot
        fadeSnapshot = nil
        snapshot?.layer.removeAllAnimations()
        snapshot?.removeFromSuperview()
    }
}
#endif
