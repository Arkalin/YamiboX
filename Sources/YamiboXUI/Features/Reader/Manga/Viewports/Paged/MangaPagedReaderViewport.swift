import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderViewport: UIViewRepresentable {
    var attachedInformation = ReaderAttachedInformationConfiguration()
    static func dismantleUIView(_ view: UICollectionView, coordinator: MangaPagedScrollCoordinator) {
        (view as? MangaPagedReaderCollectionView)?.shouldBeginPanGesture = nil
        (view as? MangaPagedReaderCollectionView)?.onLayoutSubviews = nil
        (view as? MangaPagedReaderCollectionView)?.accessibilityPageTurn = nil
        coordinator.detachViewport()
        coordinator.gestures.input.detach()
    }
    let plan: MangaPagedReadingPlan
    let viewportPlacement: MangaNovelReaderViewportPlacement?
    let settings: MangaReaderSettings
    let imageLoader: MangaReaderPageImageLoader
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let likedPageIDs: Set<String>
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
    let pagedZoom: MangaPagedZoomSession
    let onCurrentPageChange: (Int) -> Void
    let canBoundaryPageTurn: (Int) -> Bool
    let onBoundaryPageTurn: (Int) -> Void
    var onBoundaryPageTurnRejected: (Int) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.mangaViewportHandoff) var handoff
    @Environment(\.readerRemoteInput) var remoteInput
    @Environment(\.readerDeviceInteraction) var deviceInteraction

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
        coordinator.attach(to: collectionView)
        collectionView.onLayoutSubviews = { [weak coordinator, weak collectionView] in
            guard let coordinator, let collectionView else { return }
            coordinator.callbackScheduler.performViewUpdate {
                coordinator.didLayoutViewport(collectionView)
            }
        }
        context.coordinator.gestures.install(in: collectionView)
        context.coordinator.updateGestureState(in: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.updateContentIfNeeded(in: collectionView)
        }
        let gestures = context.coordinator.gestures
        controlPageTurnBridge.route = { [weak gestures] step in
            gestures?.routeControl(step)
        }
        controlPageTurnBridge.pagedSurface = { [weak gestures] in
            gestures?.currentSurface()
        }
        let coordinator = context.coordinator
        controlPageTurnBridge.capturePosition = { [weak coordinator] in
            guard let coordinator, let index = coordinator.currentSpreadIndex,
                  let spread = coordinator.parent.plan.spread(at: index) else { return nil }
            let plan = coordinator.parent.plan
            let retainedIndex = plan.currentPageIndex.flatMap { spread.containsPage(at: $0) ? $0 : nil }
            let fallback = retainedIndex.map { plan.pages[$0] } ?? spread.preferredPage
            let focus = coordinator.gestures.currentSurface()?.pageFocus
            let page = [spread.leftPage, spread.rightPage].compactMap { $0 }.first { $0.id == focus?.pageID } ?? fallback
            return .init(page: page, placement: coordinator.parent.viewportPlacement, focus: focus)
        }
    }
}

final class MangaPagedReaderCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?
    var shouldBeginPanGesture: ((UIPanGestureRecognizer) -> Bool)?
    var accessibilityPageTurn: ((UIAccessibilityScrollDirection) -> Bool)?
    private var lastViewportSize: CGSize?

    override func layoutSubviews() {
        if lastViewportSize != bounds.size {
            lastViewportSize = bounds.size
            collectionViewLayout.invalidateLayout()
        }
        super.layoutSubviews()
        onLayoutSubviews?()
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        accessibilityPageTurn?(direction) ?? false
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
