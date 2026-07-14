import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
    static let reuseIdentifier = "MangaPagedReaderPageCell"

    var parent: MangaPagedReaderViewport
    let pagingDriver = ReaderPagedPagingDriver()
    private var contentIdentity: MangaPagedReaderContentIdentity?
    private var surfaceInteractionIdentity: MangaPagedReaderSurfaceInteractionIdentity?
    private(set) var pageSurfaceInteractions: [String: MangaPagedReaderPageSurfaceInteraction] = [:]
    private(set) var spreadSurfaceInteractions: [String: MangaPagedReaderPageSurfaceInteraction] = [:]
    private var pageSurfaceInitialHorizontalAlignments: [String: MangaPagedImageSurfaceInitialHorizontalAlignment] = [:]
    private var lastAppliedLikedPageIDs: Set<String> = []
    private var pendingInitialSpreadIndex: Int?
    private var lastReportedGlobalIndex: Int?
    private var lastAppliedPlacementRevision: Int?
    private var lastLaidOutViewportSize: CGSize?
    private(set) lazy var gestures = MangaPagedScrollGestureController(coordinator: self)

    var callbackScheduler: SwiftUIViewUpdateCallbackScheduler {
        pagingDriver.callbackScheduler
    }

    var pagingInputs: ReaderPagedPagingInputs {
        pagingInputs(selectionSpreadIndex: parent.plan.currentSpreadIndex)
    }

    private func pagingInputs(selectionSpreadIndex: Int?) -> ReaderPagedPagingInputs {
        let spreadIndex = parent.plan.clampedSpreadIndex(selectionSpreadIndex) ?? 0
        return ReaderPagedPagingInputs(
            itemCount: parent.plan.spreads.count,
            selectionIndex: spreadIndex,
            pagedTurnStyle: parent.settings.pagedTurnStyle,
            horizontalNavigationDirection: parent.settings.pageTurnDirection.horizontalNavigationDirection,
            pagerIdentity: ReaderPagedPagerIdentity(
                visibleView: spreadIndex + 1,
                surfaceCount: parent.plan.pages.count,
                spreadCount: parent.plan.spreads.count,
                usesTwoPageSpread: parent.plan.usesTwoPageSpread,
                layout: .zero
            ),
            scrollAnimationRequest: nil,
            canBoundaryPageTurn: parent.canBoundaryPageTurn,
            onSelectionChange: { [weak self] spreadIndex in
                self?.publishCurrentPageIfNeeded(spreadIndex: spreadIndex)
            },
            onBoundaryPageTurn: parent.onBoundaryPageTurn,
            onScrollAnimationRequestConsumed: { _ in },
            pageTurnRestingBackgroundColor: { [parent] _ in parent.pageEdgeFillColor },
            pageTurnBackgroundColor: { [parent] _, overlayAlpha in
                ReaderPagedPageTurnBackground.dimmedPageColor(
                    baseColor: parent.pageEdgeFillColor,
                    overlayAlpha: overlayAlpha
                )
            },
            itemIndexForSelectionIndex: { [weak self] spreadIndex in
                self?.viewportIndex(forSpreadIndex: spreadIndex) ?? spreadIndex
            },
            selectionIndexForItemIndex: { [weak self] viewportIndex in
                self?.spreadIndex(forViewportIndex: viewportIndex) ?? viewportIndex
            }
        )
    }

    init(parent: MangaPagedReaderViewport) {
        self.parent = parent
    }

    func updateContentIfNeeded(in collectionView: UICollectionView) {
        prefetchAdjacentImages()
        let nextIdentity = MangaPagedReaderContentIdentity(
            spreadIDs: parent.plan.spreads.map(\.id),
            pageScaleMode: parent.effectivePageScaleMode,
            pagedTurnStyle: parent.settings.pagedTurnStyle,
            pageTurnDirection: parent.settings.pageTurnDirection,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            colorScheme: parent.colorScheme
        )
        guard nextIdentity != contentIdentity else {
            applyInitialPlacementIfNeeded(in: collectionView)
            applyViewportPlacementIfNeeded(in: collectionView)
            updateVisiblePageSurfacesIfNeeded(in: collectionView)
            return
        }

        contentIdentity = nextIdentity
        surfaceInteractionIdentity = nil
        pageSurfaceInteractions = [:]
        spreadSurfaceInteractions = [:]
        pageSurfaceInitialHorizontalAlignments = [:]
        lastReportedGlobalIndex = nil
        if parent.plan.spreads.isEmpty {
            pendingInitialSpreadIndex = nil
            collectionView.alpha = 1
        } else {
            let targetPageIndex = parent.plan.clampedPageIndex(
                parent.viewportPlacement?.targetPageIndex ?? parent.plan.currentPageIndex
            )
            pendingInitialSpreadIndex = targetPageIndex.flatMap(parent.plan.spreadIndex(forPageAt:))
                ?? parent.plan.currentSpreadIndex
            collectionView.alpha = 0
        }

        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        applyInitialPlacementIfNeeded(in: collectionView)
        applyViewportPlacementIfNeeded(in: collectionView)
        updateVisiblePageSurfacesIfNeeded(in: collectionView)
    }

    func realignViewportAfterBoundsChangeIfNeeded(in collectionView: UICollectionView) {
        let currentViewportSize = collectionView.bounds.size
        defer {
            lastLaidOutViewportSize = currentViewportSize
        }

        guard pendingInitialSpreadIndex == nil,
              let targetOffsetX = MangaPagedViewportResizePolicy.alignedContentOffsetX(
                  previousContentOffsetX: collectionView.contentOffset.x,
                  previousViewportSize: lastLaidOutViewportSize,
                  currentViewportSize: currentViewportSize,
                  itemCount: parent.plan.spreads.count
              ) else {
            return
        }

        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.setContentOffset(
            CGPoint(x: targetOffsetX, y: collectionView.contentOffset.y),
            animated: false
        )
        publishCurrentPageIfNeeded(from: collectionView)
        updateGestureState(in: collectionView)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        parent.plan.spreads.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: Self.reuseIdentifier,
            for: indexPath
        )
        let spreadIndex = spreadIndex(forViewportIndex: indexPath.item)
        guard let cell = cell as? ReaderPagedPageTurnCell,
              parent.plan.spreads.indices.contains(spreadIndex) else {
            return cell
        }

        configureSpreadCell(cell, spreadIndex: spreadIndex, refreshInitialHorizontalAlignment: true)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let spreadIndex = spreadIndex(forViewportIndex: indexPath.item)
        configureSpreadCell(cell, spreadIndex: spreadIndex, refreshInitialHorizontalAlignment: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pagingDriver.scrollViewWillBeginDragging(scrollView, inputs: pagingInputs)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pagingDriver.scrollViewDidScroll(scrollView, inputs: pagingInputs)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        pagingDriver.scrollViewDidEndDecelerating(scrollView, inputs: pagingInputs)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        pagingDriver.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate, inputs: pagingInputs)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        pagingDriver.scrollViewDidEndScrollingAnimation(scrollView, inputs: pagingInputs)
    }

    func applyInitialPlacementIfNeeded(in collectionView: UICollectionView) {
        guard let targetIndex = pendingInitialSpreadIndex else { return }
        guard parent.plan.spreads.indices.contains(targetIndex) else {
            pendingInitialSpreadIndex = nil
            collectionView.alpha = 1
            return
        }
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
            return
        }
        let targetViewportIndex = viewportIndex(forSpreadIndex: targetIndex)

        collectionView.scrollToItem(
            at: IndexPath(item: targetViewportIndex, section: 0),
            at: .centeredHorizontally,
            animated: false
        )
        lastAppliedPlacementRevision = parent.viewportPlacement?.revision
        pendingInitialSpreadIndex = nil
        collectionView.alpha = 1
        publishCurrentPageIfNeeded(from: collectionView)
        updateGestureState(in: collectionView)
    }

    func applyViewportPlacementIfNeeded(in collectionView: UICollectionView) {
        guard pendingInitialSpreadIndex == nil,
              let placement = parent.viewportPlacement,
              placement.revision != lastAppliedPlacementRevision else {
            return
        }
        guard let targetIndex = parent.plan.clampedPageIndex(placement.targetPageIndex),
              parent.plan.pages.indices.contains(targetIndex),
              let targetSpreadIndex = parent.plan.spreadIndex(forPageAt: targetIndex),
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0 else {
            return
        }

        let targetViewportIndex = viewportIndex(forSpreadIndex: targetSpreadIndex)
        let placementInputs = pagingInputs(selectionSpreadIndex: targetSpreadIndex)
        lastAppliedPlacementRevision = placement.revision
        if placement.animated {
            let didRequestDriverScroll = pagingDriver.requestSelectionScroll(
                in: collectionView,
                animated: true,
                inputs: placementInputs
            )
            if !didRequestDriverScroll {
                collectionView.scrollToItem(
                    at: IndexPath(item: targetViewportIndex, section: 0),
                    at: .centeredHorizontally,
                    animated: true
                )
            }
        } else {
            collectionView.scrollToItem(
                at: IndexPath(item: targetViewportIndex, section: 0),
                at: .centeredHorizontally,
                animated: false
            )
            publishCurrentPageIfNeeded(spreadIndex: targetSpreadIndex)
        }
    }

    func updateGestureState(in collectionView: UICollectionView) {
        pagingDriver.updateGestureState(in: collectionView, inputs: pagingInputs)
        if parent.isChromeVisible {
            collectionView.panGestureRecognizer.isEnabled = false
        }
        gestures.quickFadePanGesture.isEnabled = !parent.isChromeVisible && parent.settings.pagedTurnStyle == .quickFade
    }

    private func updateVisiblePageSurfacesIfNeeded(in collectionView: UICollectionView) {
        let nextIdentity = MangaPagedReaderSurfaceInteractionIdentity(
            isChromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled
        )
        let likedPageIDsChanged = parent.likedPageIDs != lastAppliedLikedPageIDs
        guard nextIdentity != surfaceInteractionIdentity || likedPageIDsChanged else { return }
        surfaceInteractionIdentity = nextIdentity
        lastAppliedLikedPageIDs = parent.likedPageIDs

        for case let cell as ReaderPagedPageTurnCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let spreadIndex = spreadIndex(forViewportIndex: indexPath.item)
            configureSpreadCell(cell, spreadIndex: spreadIndex, refreshInitialHorizontalAlignment: false)
        }
    }

    private func configureSpreadCell(
        _ cell: UICollectionViewCell,
        spreadIndex: Int,
        refreshInitialHorizontalAlignment: Bool
    ) {
        guard let cell = cell as? ReaderPagedPageTurnCell,
              parent.plan.spreads.indices.contains(spreadIndex) else {
            return
        }

        let spread = parent.plan.spreads[spreadIndex]
        cell.configure(
            spreadID: spread.id,
            usesTwoPageSpread: parent.plan.usesTwoPageSpread,
            leftPageSurface: pageSurface(
                page: spread.leftPage,
                pageIndex: spread.leftPageIndex,
                refreshInitialHorizontalAlignment: refreshInitialHorizontalAlignment
            ),
            rightPageSurface: pageSurface(
                page: spread.rightPage,
                pageIndex: spread.rightPageIndex,
                refreshInitialHorizontalAlignment: refreshInitialHorizontalAlignment
            ),
            imageLoader: parent.imageLoader,
            pageScaleMode: parent.effectivePageScaleMode,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            isChromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled,
            allowsUnzoomedSurfacePan: true,
            spreadSurfaceInteraction: spreadSurfaceInteraction(for: spread),
            likedPageIDs: parent.likedPageIDs,
            colorScheme: parent.colorScheme
        )
        cell.resetPageTurnVisuals()
    }

    private func prefetchAdjacentImages() {
        let pagesToPrefetch = MangaPagedImagePrefetchPlan.pagesToPrefetch(plan: parent.plan)
        parent.imageLoader.prefetchImages(for: pagesToPrefetch)
    }

    private func pageSurface(
        page: MangaReaderPageProjection?,
        pageIndex: Int?,
        refreshInitialHorizontalAlignment: Bool
    ) -> MangaPagedReaderSpreadPageSurface? {
        guard let page, let pageIndex else { return nil }
        return MangaPagedReaderSpreadPageSurface(
            page: page,
            surfaceIdentity: MangaPagedReaderPageAppearanceIdentity(pageID: page.id, appearanceGeneration: 0),
            initialHorizontalAlignment: initialHorizontalAlignment(
                for: page,
                pageIndex: pageIndex,
                refresh: refreshInitialHorizontalAlignment
            ),
            surfaceInteraction: surfaceInteraction(for: page),
            onLongPress: { [weak self] page in
                guard let self else { return }
                let onPageLongPress = self.parent.onPageLongPress
                self.callbackScheduler.publish {
                    onPageLongPress(page)
                }
            }
        )
    }

    private func initialHorizontalAlignment(
        for page: MangaReaderPageProjection,
        pageIndex: Int,
        refresh: Bool
    ) -> MangaPagedImageSurfaceInitialHorizontalAlignment {
        if !refresh, let alignment = pageSurfaceInitialHorizontalAlignments[page.id] {
            return alignment
        }

        let alignment = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: parent.settings.pageTurnDirection,
            pageScaleMode: parent.effectivePageScaleMode,
            currentPageIndex: parent.plan.currentPageIndex,
            targetPageIndex: pageIndex
        )
        pageSurfaceInitialHorizontalAlignments[page.id] = alignment
        return alignment
    }

    private func surfaceInteraction(for page: MangaReaderPageProjection) -> MangaPagedReaderPageSurfaceInteraction {
        if let interaction = pageSurfaceInteractions[page.id] {
            return interaction
        }
        let interaction = MangaPagedReaderPageSurfaceInteraction()
        pageSurfaceInteractions[page.id] = interaction
        return interaction
    }

    private func spreadSurfaceInteraction(for spread: MangaPageSpread) -> MangaPagedReaderPageSurfaceInteraction {
        if let interaction = spreadSurfaceInteractions[spread.id] {
            return interaction
        }
        let interaction = MangaPagedReaderPageSurfaceInteraction()
        spreadSurfaceInteractions[spread.id] = interaction
        return interaction
    }

    private func publishCurrentPageIfNeeded(spreadIndex: Int) {
        guard let globalIndex = parent.plan.globalIndex(forSpreadAt: spreadIndex),
              globalIndex != lastReportedGlobalIndex else {
            return
        }

        lastReportedGlobalIndex = globalIndex
        let onCurrentPageChange = parent.onCurrentPageChange
        callbackScheduler.publish {
            onCurrentPageChange(globalIndex)
        }
    }

    private func publishCurrentPageIfNeeded(from collectionView: UICollectionView) {
        guard let spreadIndex = currentSpreadIndex(in: collectionView),
              parent.plan.spreads.indices.contains(spreadIndex) else {
            return
        }
        publishCurrentPageIfNeeded(spreadIndex: spreadIndex)
    }

    func currentSpreadIndex(in collectionView: UICollectionView) -> Int? {
        guard collectionView.bounds.width > 0 else {
            return parent.plan.currentSpreadIndex
        }
        let rawIndex = Int((collectionView.contentOffset.x / collectionView.bounds.width).rounded())
        return parent.plan.clampedSpreadIndex(spreadIndex(forViewportIndex: rawIndex))
    }

    func viewportIndex(forSpreadIndex spreadIndex: Int) -> Int {
        guard !parent.plan.spreads.isEmpty,
              let clampedSpreadIndex = parent.plan.clampedSpreadIndex(spreadIndex) else {
            return 0
        }
        switch parent.settings.pageTurnDirection {
        case .leftToRight:
            return clampedSpreadIndex
        case .rightToLeft:
            return parent.plan.spreads.count - 1 - clampedSpreadIndex
        }
    }

    private func spreadIndex(forViewportIndex viewportIndex: Int) -> Int {
        guard !parent.plan.spreads.isEmpty else { return 0 }
        let clampedViewportIndex = min(max(viewportIndex, 0), parent.plan.spreads.count - 1)
        switch parent.settings.pageTurnDirection {
        case .leftToRight:
            return clampedViewportIndex
        case .rightToLeft:
            return parent.plan.spreads.count - 1 - clampedViewportIndex
        }
    }
}
#endif
