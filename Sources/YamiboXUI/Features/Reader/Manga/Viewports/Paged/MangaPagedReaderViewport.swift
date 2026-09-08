import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderViewport: UIViewRepresentable {
    static func dismantleUIView(_ view: UICollectionView, coordinator: MangaPagedScrollCoordinator) {
        coordinator.pagingDriver.cancelSlideTransition(in: view, inputs: coordinator.pagingInputs)
        (view as? MangaPagedReaderCollectionView)?.shouldBeginPanGesture = nil
        (view as? MangaPagedReaderCollectionView)?.onLayoutSubviews = nil
        coordinator.gestures.input.detach()
        coordinator.interactionRuntime.reset()
    }
    let plan: MangaPagedReadingPlan
    let viewportPlacement: MangaNovelReaderViewportPlacement?
    let settings: MangaReaderSettings
    let imageLoader: MangaReaderPageImageLoader
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let likedPageIDs: Set<String>
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
    let onCurrentPageChange: (Int) -> Void
    let canBoundaryPageTurn: (Int) -> Bool
    let onBoundaryPageTurn: (Int) -> Void
    var onBoundaryPageTurnRejected: (Int) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var pageEdgeFillColor: UIColor {
        settings.pageEdgeFillStyle.uiColor(for: colorScheme)
    }

    var effectivePageScaleMode: MangaPageScaleMode {
        MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: settings,
            usesTwoPageSpread: plan.usesTwoPageSpread
        )
    }

    func makeCoordinator() -> MangaPagedScrollCoordinator {
        MangaPagedScrollCoordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let collectionView = MangaPagedReaderCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.isPagingEnabled = true
        collectionView.alwaysBounceHorizontal = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = pageEdgeFillColor
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            ReaderPagedPageTurnCell.self,
            forCellWithReuseIdentifier: MangaPagedScrollCoordinator.reuseIdentifier
        )
        let coordinator = context.coordinator
        collectionView.onLayoutSubviews = { [weak coordinator, weak collectionView] in
            guard let coordinator, let collectionView else { return }
            // Layout can run inside the SwiftUI render commit; defer callbacks
            // published by the placement work out of the update transaction.
            coordinator.callbackScheduler.performViewUpdate {
                coordinator.realignViewportAfterBoundsChangeIfNeeded(in: collectionView)
                coordinator.applyInitialPlacementIfNeeded(in: collectionView)
                coordinator.applyViewportPlacementIfNeeded(in: collectionView)
            }
        }
        context.coordinator.gestures.install(in: collectionView)
        context.coordinator.updateGestureState(in: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        collectionView.backgroundColor = pageEdgeFillColor
        context.coordinator.updateGestureState(in: collectionView)
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.updateContentIfNeeded(in: collectionView)
        }
        let gestures = context.coordinator.gestures
        controlPageTurnBridge.route = { [weak gestures, weak collectionView] step in
            guard let gestures, let collectionView else { return }
            gestures.routeControl(step, in: collectionView)
        }
    }
}

final class MangaPagedReaderCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?
    var shouldBeginPanGesture: ((UIPanGestureRecognizer) -> Bool)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard super.gestureRecognizerShouldBegin(gestureRecognizer) else {
            return false
        }
        guard gestureRecognizer === panGestureRecognizer,
              let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
              let shouldBeginPanGesture else {
            return true
        }
        return shouldBeginPanGesture(panRecognizer)
    }
}
#endif
