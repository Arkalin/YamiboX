#if os(iOS)
import UIKit

/// Updates the real scroll position so cells and page-turn shading stay in sync.
/// Unlike UIScrollView's animated offset, a new touch cannot pause this clock.
@MainActor
final class ReaderPagedSlideAnimation {
    private weak var collectionView: UICollectionView?
    private let startOffset: CGPoint
    private let targetOffset: CGPoint
    private let viewportSize: CGSize
    private let startTime = CACurrentMediaTime()
    private let completion: (Bool) -> Void
    private var displayLink: CADisplayLink?

    init(in collectionView: UICollectionView, targetOffset: CGPoint, completion: @escaping (Bool) -> Void) {
        self.collectionView = collectionView
        startOffset = collectionView.contentOffset
        self.targetOffset = targetOffset
        viewportSize = collectionView.bounds.size
        self.completion = completion
        let target = DisplayLinkTarget()
        target.animation = self
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.advance(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    deinit {
        MainActor.assumeIsolated { cancel() }
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func advance(elapsedTime: CFTimeInterval) {
        guard displayLink != nil else { return }
        guard let collectionView, collectionView.window != nil,
              collectionView.bounds.size == viewportSize, !collectionView.isDragging else {
            cancel()
            completion(false)
            return
        }
        let progress = min(max(elapsedTime / 0.3, 0), 1)
        let easedProgress = 1 - pow(1 - progress, 3)
        collectionView.setContentOffset(CGPoint(
            x: startOffset.x + (targetOffset.x - startOffset.x) * easedProgress,
            y: startOffset.y + (targetOffset.y - startOffset.y) * easedProgress
        ), animated: false)
        collectionView.layoutIfNeeded()
        guard displayLink != nil, progress == 1 else { return }
        cancel()
        completion(true)
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var animation: ReaderPagedSlideAnimation?

        @objc func advance(_ displayLink: CADisplayLink) {
            guard let animation else { return }
            animation.advance(elapsedTime: displayLink.targetTimestamp - animation.startTime)
        }
    }
}
#endif
