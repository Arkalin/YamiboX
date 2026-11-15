import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
    static let reuseIdentifier = "MangaPagedReaderPageCell"

    private enum SlideAlignment {
        case drag
        case anchor
    }

    var parent: MangaPagedReaderViewport
    let informationState = ReaderAttachedInformationState()
    let pagingDriver = ReaderPagedPagingDriver(commitsQuickFadeSelectionImmediately: true)
    private(set) lazy var interactionRuntime = MangaPagedInteractionRuntime(zoomSession: parent.pagedZoom) { [weak self] in
        self?.parent.settings.zoomAnimationEnabled ?? true
    }
    private var contentIdentity: MangaPagedReaderContentIdentity?
    private var surfaceInteractionIdentity: MangaPagedReaderSurfaceInteractionIdentity?
    private var pageSurfaceInteractions: [String: MangaSurfaceAttachment] = [:]
    private var spreadSurfaceInteractions: [String: MangaSurfaceAttachment] = [:]
    private var lastAppliedLikedPageIDs: Set<String> = []
    private var pendingInitialSpreadIndex: Int?
    private var lastReportedGlobalIndex: Int?
    private var lastHandledPlacementRevision: Int?
    private var animatingSlidePlacementRevision: Int?
    private var lastLaidOutViewportSize: CGSize?
    private weak var collectionView: UICollectionView?
    private var settledSlideSpreadIndex: Int?
    private var pendingSlideAlignment: SlideAlignment?
    private var pagingSettlementDisplayLink: CADisplayLink?
    private var isAligningSlide = false
    private let imagePrefetch: MangaPagedImagePrefetchSession
    private(set) lazy var gestures = MangaPagedScrollNavigationAdapter(coordinator: self)

    var callbackScheduler: SwiftUIViewUpdateCallbackScheduler {
        pagingDriver.callbackScheduler
    }

    var pagingInputs: ReaderPagedPagingInputs {
        let slideSelection = usesSlidePaging ? settledSlideSpreadIndex : nil
        return pagingInputs(selectionSpreadIndex: slideSelection ?? parent.plan.currentSpreadIndex)
    }

    private var usesSlidePaging: Bool { parent.settings.pagedTurnStyle == .slide }

    private var hasUnappliedViewportPlacement: Bool {
        guard let placement = parent.viewportPlacement else { return false }
        return placement.revision != lastHandledPlacementRevision
    }

    private func pagingInputs(selectionSpreadIndex: Int?) -> ReaderPagedPagingInputs {
        let spreadIndex = parent.plan.clampedSpreadIndex(selectionSpreadIndex) ?? 0
        let contentIdentity = contentIdentity
        let placementRevision = parent.viewportPlacement?.revision
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
            onBoundaryPageTurn: parent.onBoundaryPageTurn,
            onBoundaryPageTurnRejected: parent.onBoundaryPageTurnRejected,
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
            },
            onSelectionSettled: { [weak self] spreadIndex in
                // Slide commits only after its own geometry-based alignment.
                guard let self, !self.usesSlidePaging, self.contentIdentity == contentIdentity,
                      self.parent.viewportPlacement?.revision == placementRevision else { return }
                self.commitVisibleSpread(spreadIndex)
            }
        )
    }

    init(parent: MangaPagedReaderViewport) {
        self.parent = parent
        imagePrefetch = MangaPagedImagePrefetchSession(loader: parent.imageLoader)
    }

    func attach(to collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    func detachViewport() {
        collectionView = nil
        resetSlideSettlement()
    }

    func updateContentIfNeeded(in collectionView: UICollectionView) {
        informationState.update(parent.attachedInformation)
        prefetchAdjacentImages()
        let nextIdentity = MangaPagedReaderContentIdentity(
            spreadIDs: parent.plan.spreadIDs,
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
        resetSlideSettlement()
        pagingDriver.cancelSelectionScroll(in: collectionView, inputs: pagingInputs)
        interactionRuntime.reset()
        surfaceInteractionIdentity = nil
        pageSurfaceInteractions = [:]
        spreadSurfaceInteractions = [:]
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

        // UIKit may already have clamped the offset to the new content size.
        // Preserve the logical selection instead of interpreting that offset with the old width.
        guard pendingInitialSpreadIndex == nil,
              let spreadIndex = parent.plan.currentSpreadIndex,
              let targetOffsetX = MangaPagedViewportResizePolicy.alignedContentOffsetX(
                  itemIndex: viewportIndex(forSpreadIndex: spreadIndex),
                  previousViewportSize: lastLaidOutViewportSize,
                  currentViewportSize: currentViewportSize,
                  itemCount: parent.plan.spreads.count
              ) else {
            return
        }

        pagingDriver.cancelSelectionScroll(in: collectionView, inputs: pagingInputs)
        collectionView.collectionViewLayout.invalidateLayout()
        if usesSlidePaging {
            // A model placement not yet completed is reapplied from the
            // latest revision. A genuine native drag still owns its landing.
            animatingSlidePlacementRevision = nil
            if case .drag = pendingSlideAlignment {
                return
            }
            pendingSlideAlignment = .anchor
            return
        }
        collectionView.setContentOffset(
            CGPoint(x: targetOffsetX, y: collectionView.contentOffset.y),
            animated: false
        )
        // A resize only restores placement; it must not change reading progress.
        activatePageEntry(at: spreadIndex)
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

        configureSpreadCell(cell, spreadIndex: spreadIndex)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let spreadIndex = spreadIndex(forViewportIndex: indexPath.item)
        configureSpreadCell(cell, spreadIndex: spreadIndex)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if usesSlidePaging {
            // If UIKit already started an outer drag while the image owns the
            // pan, don't interpret its eventual end as a page turn.
            guard !slideImageOwnsPan else { return }
            if let revision = animatingSlidePlacementRevision {
                // A new native turn takes over the in-flight slide.
                lastHandledPlacementRevision = revision
                animatingSlidePlacementRevision = nil
            }
            scheduleSlideAlignment(.drag)
        }
        pagingDriver.scrollViewWillBeginDragging(scrollView, inputs: pagingInputs)
        if let collectionView = scrollView as? UICollectionView {
            prepareVisiblePageEntries(in: collectionView)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAligningSlide else { return }
        if let collectionView = scrollView as? UICollectionView,
           let index = restingSlideSpreadIndex, slideImageOwnsPan {
            if !alignSlide(to: index, in: collectionView, stopUnexpectedMotion: true) {
                scheduleSlideAlignment(.anchor)
            }
            return
        }
        pagingDriver.scrollViewDidScroll(scrollView, inputs: pagingInputs)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if usesSlidePaging {
            if hasUnappliedViewportPlacement {
                scrollView.setNeedsLayout()
            } else {
                settlePagingIfIdle()
            }
            return
        }
        pagingDriver.scrollViewDidEndDecelerating(scrollView, inputs: pagingInputs)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if usesSlidePaging {
            if hasUnappliedViewportPlacement {
                // The pending explicit navigation supersedes this drag's landing,
                // but may only be applied after UIKit has released the pan.
                scrollView.setNeedsLayout()
                return
            }
            guard case .drag = pendingSlideAlignment else { return }
        }
        pagingDriver.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate, inputs: pagingInputs)
        if usesSlidePaging, !decelerate { settlePagingIfIdle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if usesSlidePaging {
            // UIKit can move an unzoomed viewport without a drag (for example
            // for accessibility). Don't treat that as image-owned drift.
            if pendingSlideAlignment == nil, !isAligningSlide, !slideImageOwnsPan {
                scheduleSlideAlignment(.drag)
            }
            return
        }
        pagingDriver.scrollViewDidEndScrollingAnimation(scrollView, inputs: pagingInputs)
    }

    private var restingSlideSpreadIndex: Int? {
        guard usesSlidePaging, pendingInitialSpreadIndex == nil, !hasUnappliedViewportPlacement,
              !pagingDriver.isPerformingSlideTransition else { return nil }
        if case .drag = pendingSlideAlignment { return nil }
        return settledSlideSpreadIndex
    }

    var slideImageOwnsPan: Bool {
        guard let index = restingSlideSpreadIndex else { return false }
        return surface(forSpreadAt: index)?.keepsPageFixedDuringImageInteraction == true
    }

    private func scheduleSlideAlignment(_ alignment: SlideAlignment) {
        pendingSlideAlignment = alignment
        startPagingSettlementObservation()
    }

    private func startPagingSettlementObservation() {
        guard pagingSettlementDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(settlePagingIfIdle))
        pagingSettlementDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    private func stopPagingSettlementObservation() {
        pagingSettlementDisplayLink?.invalidate()
        pagingSettlementDisplayLink = nil
    }

    private func clearPendingSlideAlignment() {
        stopPagingSettlementObservation()
        pendingSlideAlignment = nil
    }

    private func resetSlideSettlement() {
        clearPendingSlideAlignment()
        settledSlideSpreadIndex = nil
        animatingSlidePlacementRevision = nil
    }

    func reconcileSlideAfterLayout() {
        guard usesSlidePaging, !isAligningSlide else { return }
        if pendingSlideAlignment == nil {
            guard let collectionView, let index = restingSlideSpreadIndex, slideImageOwnsPan else { return }
            checkSlideAnchor(at: index, in: collectionView)
        }
        settlePagingIfIdle()
    }

    private func checkSlideAnchor(at index: Int, in collectionView: UICollectionView) {
        if let x = alignedSlideOffsetX(for: index, in: collectionView),
           abs(collectionView.contentOffset.x - x) <= slideAlignmentTolerance(in: collectionView) { return }
        scheduleSlideAlignment(.anchor)
    }

    @objc private func settlePagingIfIdle() {
        guard let collectionView, collectionView.window != nil, usesSlidePaging,
              let alignment = pendingSlideAlignment,
              pendingInitialSpreadIndex == nil, !hasUnappliedViewportPlacement else {
            stopPagingSettlementObservation()
            return
        }

        guard !isAligningSlide else { return }
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !collectionView.isScrollAnimating, !pagingDriver.isPerformingSlideTransition else {
            startPagingSettlementObservation()
            return
        }

        let spreadIndex: Int?
        switch alignment {
        case .drag:
            // For actual swipes, choose the spread covering the viewport
            // center. Image motion must never use this to select a new page.
            let bounds = collectionView.bounds
            spreadIndex = collectionView.indexPathForItem(at: CGPoint(x: bounds.midX, y: bounds.midY))
                .map { self.spreadIndex(forViewportIndex: $0.item) }
                ?? nearestSpreadIndex(in: collectionView)
        case .anchor:
            spreadIndex = settledSlideSpreadIndex ?? parent.plan.currentSpreadIndex
        }
        guard let spreadIndex, alignSlide(to: spreadIndex, in: collectionView) else {
            // Wait for the next layout instead of dropping the old anchor or
            // probing invalid attributes on every frame.
            stopPagingSettlementObservation()
            return
        }

        clearPendingSlideAlignment()
        switch alignment {
        case .drag:
            pagingDriver.cancelSlideTransition(in: collectionView, inputs: pagingInputs)
            confirmSlideLanding(at: spreadIndex, publishesProgress: true)
        case .anchor:
            confirmSlideLanding(at: spreadIndex, publishesProgress: false)
        }
    }

    private func alignedSlideOffsetX(for spreadIndex: Int, in collectionView: UICollectionView) -> CGFloat? {
        let size = collectionView.bounds.size
        guard size.width > 0, size.height > 0, size == lastLaidOutViewportSize,
              parent.plan.spreads.indices.contains(spreadIndex),
              collectionView.numberOfSections > 0 else { return nil }
        let item = viewportIndex(forSpreadIndex: spreadIndex)
        let tolerance = slideAlignmentTolerance(in: collectionView)
        guard collectionView.numberOfItems(inSection: 0) > item,
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame,
              abs(frame.width - size.width) <= tolerance else { return nil }
        let offsetX = frame.midX - size.width / 2
        let insets = collectionView.adjustedContentInset
        let minX = -insets.left
        let maxX = max(minX, collectionView.contentSize.width - size.width + insets.right)
        guard offsetX >= minX - tolerance, offsetX <= maxX + tolerance else { return nil }
        return min(max(offsetX, minX), maxX)
    }

    private func slideAlignmentTolerance(in collectionView: UICollectionView) -> CGFloat {
        0.5 / max(collectionView.traitCollection.displayScale, 1)
    }

    @discardableResult
    private func alignSlide(
        to spreadIndex: Int,
        in collectionView: UICollectionView,
        stopUnexpectedMotion: Bool = false
    ) -> Bool {
        guard let offsetX = alignedSlideOffsetX(for: spreadIndex, in: collectionView) else { return false }
        guard abs(collectionView.contentOffset.x - offsetX) > slideAlignmentTolerance(in: collectionView) else { return true }
        isAligningSlide = true
        defer { isAligningSlide = false }
        UIView.performWithoutAnimation {
            if stopUnexpectedMotion, collectionView.isDecelerating || collectionView.isScrollAnimating {
                collectionView.stopScrollingAndZooming()
            }
            collectionView.setContentOffset(CGPoint(x: offsetX, y: collectionView.contentOffset.y), animated: false)
        }
        return abs(collectionView.contentOffset.x - offsetX) <= slideAlignmentTolerance(in: collectionView)
    }

    func applyInitialPlacementIfNeeded(in collectionView: UICollectionView) {
        guard !isAligningSlide, let initialSpreadIndex = pendingInitialSpreadIndex else { return }
        let placement = parent.viewportPlacement
        // A newer jump can arrive while the first layout is unavailable.
        // Resolve the page and acknowledge the revision from the same request.
        let placementSpreadIndex = usesSlidePaging ? placement.flatMap(spreadIndex(for:)) : nil
        let targetIndex = placementSpreadIndex ?? initialSpreadIndex
        guard parent.plan.spreads.indices.contains(targetIndex) else {
            pendingInitialSpreadIndex = nil
            collectionView.alpha = 1
            return
        }
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
            return
        }
        preparePageEntry(at: targetIndex)
        pagingDriver.cancelSelectionScroll(in: collectionView, inputs: pagingInputs)
        if usesSlidePaging {
            guard alignSlide(to: targetIndex, in: collectionView) else { return }
            settledSlideSpreadIndex = targetIndex
        } else {
            collectionView.scrollToItem(
                at: IndexPath(item: viewportIndex(forSpreadIndex: targetIndex), section: 0),
                at: .centeredHorizontally,
                animated: false
            )
        }
        activatePageEntry(at: targetIndex)
        lastHandledPlacementRevision = placement?.revision
        pendingInitialSpreadIndex = nil
        collectionView.alpha = 1
        // The intended image may be the second half of the restored spread.
        // Don't turn initial placement into a new page selection.
        lastReportedGlobalIndex = parent.plan.globalIndex(forSpreadAt: targetIndex)
        updateGestureState(in: collectionView)
    }

    func applyViewportPlacementIfNeeded(in collectionView: UICollectionView) {
        guard pendingInitialSpreadIndex == nil, !isAligningSlide,
              let placement = parent.viewportPlacement,
              placement.revision != lastHandledPlacementRevision else {
            return
        }
        guard let targetSpreadIndex = spreadIndex(for: placement),
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0 else {
            return
        }

        let placementInputs = pagingInputs(selectionSpreadIndex: targetSpreadIndex)
        preparePageEntry(at: targetSpreadIndex)
        if usesSlidePaging {
            guard !collectionView.isDragging, placement.revision != animatingSlidePlacementRevision,
                  let x = alignedSlideOffsetX(for: targetSpreadIndex, in: collectionView) else { return }
            if placement.animated, collectionView.window != nil {
                animateSlide(to: targetSpreadIndex, offsetX: x, in: collectionView, inputs: placementInputs,
                             placementRevision: placement.revision)
            } else {
                resetSlideSettlement()
                pagingDriver.cancelSlideTransition(in: collectionView, inputs: placementInputs)
                guard alignSlide(to: targetSpreadIndex, in: collectionView, stopUnexpectedMotion: true) else { return }
                lastHandledPlacementRevision = placement.revision
                confirmSlideLanding(at: targetSpreadIndex, publishesProgress: false)
            }
            return
        }

        let targetViewportIndex = viewportIndex(forSpreadIndex: targetSpreadIndex)
        lastHandledPlacementRevision = placement.revision
        pagingDriver.cancelSelectionScroll(in: collectionView, inputs: pagingInputs)
        if placement.animated {
            if pagingDriver.requestSelectionScroll(in: collectionView, animated: true, inputs: placementInputs) { return }
            // A detached or not-yet-laid-out UIKit viewport may not send animation completion.
            pagingDriver.cancelSelectionScroll(in: collectionView, inputs: pagingInputs)
        }
        collectionView.scrollToItem(
            at: IndexPath(item: targetViewportIndex, section: 0),
            at: .centeredHorizontally,
            animated: false
        )
        commitVisibleSpread(targetSpreadIndex)
    }

    private func spreadIndex(for placement: MangaNovelReaderViewportPlacement) -> Int? {
        parent.plan.clampedPageIndex(placement.targetPageIndex).flatMap(parent.plan.spreadIndex(forPageAt:))
    }

    func animateAdjacentSelection(
        for step: NavigationStep,
        targetSpreadIndex: Int,
        in collectionView: UICollectionView,
        inputs: ReaderPagedPagingInputs
    ) {
        preparePageEntry(at: targetSpreadIndex)
        if usesSlidePaging {
            guard !hasUnappliedViewportPlacement, collectionView.window != nil,
                  let x = alignedSlideOffsetX(for: targetSpreadIndex, in: collectionView) else { return }
            animateSlide(to: targetSpreadIndex, offsetX: x, in: collectionView, inputs: inputs)
        } else {
            _ = pagingDriver.animateAdjacentSelection(for: step.readerTapZone, in: collectionView, inputs: inputs)
        }
    }

    private func animateSlide(
        to spreadIndex: Int,
        offsetX: CGFloat,
        in collectionView: UICollectionView,
        inputs: ReaderPagedPagingInputs,
        placementRevision: Int? = nil
    ) {
        resetSlideSettlement()
        animatingSlidePlacementRevision = placementRevision
        pagingDriver.slideToResolvedOffset(offsetX, selectionIndex: spreadIndex, in: collectionView, inputs: inputs) {
            [weak self, weak collectionView] completed in
            guard let self, let collectionView, self.collectionView === collectionView else { return }
            self.animatingSlidePlacementRevision = nil
            let isCurrent = placementRevision.map { self.parent.viewportPlacement?.revision == $0 }
                ?? !self.hasUnappliedViewportPlacement
            guard isCurrent else {
                collectionView.setNeedsLayout()
                return
            }
            guard completed, self.alignSlide(to: spreadIndex, in: collectionView) else {
                if placementRevision != nil {
                    // Do not consume a model request that hasn't reached its target.
                    collectionView.setNeedsLayout()
                } else if !collectionView.isDragging {
                    self.scheduleSlideAlignment(.anchor)
                }
                return
            }
            if let placementRevision { self.lastHandledPlacementRevision = placementRevision }
            // Commit in the animation's actual completion, even if a touch is
            // already tracking, so the next command starts on the new spread.
            self.confirmSlideLanding(at: spreadIndex, publishesProgress: placementRevision == nil)
        }
    }

    func updateGestureState(in collectionView: UICollectionView) {
        pagingDriver.updateGestureState(in: collectionView, inputs: pagingInputs)
        // Admission is checked at gesture begin; chrome updates leave ongoing
        // recognizers untouched.
        gestures.discretePagePanGesture.isEnabled = parent.settings.pagedTurnStyle.usesDiscretePageTurns
    }

    private func updateVisiblePageSurfacesIfNeeded(in collectionView: UICollectionView) {
        let nextIdentity = MangaPagedReaderSurfaceInteractionIdentity(
            isChromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled
        )
        let likedPageIDsChanged = parent.likedPageIDs != lastAppliedLikedPageIDs
        guard nextIdentity != surfaceInteractionIdentity || likedPageIDsChanged else { return }
        let needsContentUpdate = nextIdentity.zoomEnabled != surfaceInteractionIdentity?.zoomEnabled || likedPageIDsChanged
        surfaceInteractionIdentity = nextIdentity
        lastAppliedLikedPageIDs = parent.likedPageIDs
        for surface in Array(pageSurfaceInteractions.values) + Array(spreadSurfaceInteractions.values) {
            surface.runtime.setChromeVisible(parent.isChromeVisible)
        }
        // UIHostingConfiguration can detach a representable while replacing its
        // content. A policy-only chrome update must not interrupt native input.
        guard needsContentUpdate else { return }

        for case let cell as ReaderPagedPageTurnCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            let spreadIndex = spreadIndex(forViewportIndex: indexPath.item)
            configureSpreadCell(cell, spreadIndex: spreadIndex)
        }
    }

    private func configureSpreadCell(_ cell: UICollectionViewCell, spreadIndex: Int) {
        guard let cell = cell as? ReaderPagedPageTurnCell,
              parent.plan.spreads.indices.contains(spreadIndex) else {
            return
        }

        let spread = parent.plan.spreads[spreadIndex]
        preparePageEntry(at: spreadIndex)
        cell.configure(
            informationState: informationState,
            informationIndex: spreadIndex,
            usesTwoPageSpread: parent.plan.usesTwoPageSpread,
            leftPageSurface: pageSurface(spread.leftPage),
            rightPageSurface: pageSurface(spread.rightPage),
            imageLoader: parent.imageLoader,
            pageScaleMode: parent.effectivePageScaleMode,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            zoomEnabled: parent.zoomEnabled,
            allowsUnzoomedSurfacePan: true,
            spreadSurfaceInteraction: spreadSurfaceInteraction(for: spread),
            likedPageIDs: parent.likedPageIDs,
            colorScheme: parent.colorScheme,
            handoff: parent.handoff
        )
        cell.resetPageTurnVisuals()
    }

    private func prefetchAdjacentImages() {
        imagePrefetch.update(plan: parent.plan, loader: parent.imageLoader)
    }

    func stopImagePrefetch() {
        imagePrefetch.stop()
    }

    private func pageSurface(_ page: MangaReaderPageProjection?) -> MangaPagedReaderSpreadPageSurface? {
        guard let page else { return nil }
        return MangaPagedReaderSpreadPageSurface(
            page: page,
            surfaceIdentity: MangaPagedReaderPageAppearanceIdentity(pageID: page.id, appearanceGeneration: 0),
            initialHorizontalAlignment: pageEntryAlignment,
            surfaceInteraction: surfaceInteraction(for: page),
            onLongPress: { [weak self] page in
                guard let self else { return }
                let onPageLongPress = self.parent.onPageLongPress
                let generation = self.interactionRuntime.navigationGeneration
                self.callbackScheduler.publish { [weak self] in
                    guard self?.interactionRuntime.navigationGeneration == generation else { return }
                    onPageLongPress(page)
                }
            }
        )
    }

    private func surfaceInteraction(for page: MangaReaderPageProjection) -> MangaSurfaceAttachment {
        if let interaction = pageSurfaceInteractions[page.id] {
            return interaction
        }
        let interaction = MangaSurfaceAttachment(runtime: interactionRuntime.surface(SurfaceID(value: "page:" + page.id)))
        interaction.runtime.setChromeVisible(parent.isChromeVisible)
        observeSlideImageInteractionEnd(in: interaction.runtime)
        pageSurfaceInteractions[page.id] = interaction
        return interaction
    }

    private func spreadSurfaceInteraction(for spread: MangaPageSpread) -> MangaSurfaceAttachment {
        if let interaction = spreadSurfaceInteractions[spread.id] {
            return interaction
        }
        let interaction = MangaSurfaceAttachment(runtime: interactionRuntime.surface(SurfaceID(value: "spread:" + spread.id)))
        interaction.runtime.setChromeVisible(parent.isChromeVisible)
        observeSlideImageInteractionEnd(in: interaction.runtime)
        spreadSurfaceInteractions[spread.id] = interaction
        return interaction
    }

    private func observeSlideImageInteractionEnd(in runtime: MangaSurfaceRuntime) {
        guard usesSlidePaging else { return }
        runtime.onNativeInteractionEnd = { [weak self, weak runtime] in
            guard let self, let runtime, let collectionView = self.collectionView, let index = self.restingSlideSpreadIndex,
                  self.surface(forSpreadAt: index) === runtime else { return }
            self.checkSlideAnchor(at: index, in: collectionView)
        }
    }

    func surface(forSpreadAt spreadIndex: Int) -> MangaSurfaceRuntime? {
        guard let spread = parent.plan.spread(at: spreadIndex) else { return nil }
        return parent.plan.usesTwoPageSpread
            ? spreadSurfaceInteractions[spread.id]?.runtime
            : pageSurfaceInteractions[spread.preferredPage.id]?.runtime
    }

    private func confirmSlideLanding(at spreadIndex: Int, publishesProgress: Bool) {
        settledSlideSpreadIndex = spreadIndex
        commitVisibleSpread(spreadIndex, publishesProgress: publishesProgress)
    }

    private func commitVisibleSpread(_ spreadIndex: Int, publishesProgress: Bool = true) {
        activatePageEntry(at: spreadIndex)
        guard let globalIndex = parent.plan.globalIndex(forSpreadAt: spreadIndex),
              globalIndex != lastReportedGlobalIndex else {
            return
        }

        lastReportedGlobalIndex = globalIndex
        // Preserve an exact model-selected page instead of publishing its spread's preferred page.
        guard publishesProgress, parent.plan.currentSpreadIndex != spreadIndex || parent.plan.currentPageIndex == nil else { return }
        let onCurrentPageChange = parent.onCurrentPageChange
        callbackScheduler.publish {
            onCurrentPageChange(globalIndex)
        }
    }

    func currentSpreadIndex(in collectionView: UICollectionView) -> Int? {
        restingSlideSpreadIndex ?? nearestSpreadIndex(in: collectionView)
    }

    private func surfaceID(for spread: MangaPageSpread) -> SurfaceID {
        SurfaceID(value: parent.plan.usesTwoPageSpread ? "spread:" + spread.id : "page:" + spread.preferredPage.id)
    }

    private var pageEntryAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment {
        .init(pageTurnDirection: parent.settings.pageTurnDirection)
    }

    func preparePageEntry(at index: Int) {
        guard let spread = parent.plan.spread(at: index) else { return }
        interactionRuntime.prepare(surfaceID(for: spread), alignment: pageEntryAlignment)
    }

    private func prepareVisiblePageEntries(in collectionView: UICollectionView) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            preparePageEntry(at: spreadIndex(forViewportIndex: indexPath.item))
        }
    }

    private func activatePageEntry(at index: Int) {
        guard let spread = parent.plan.spread(at: index) else { return }
        interactionRuntime.activate(surfaceID(for: spread), selectionID: spread.id, alignment: pageEntryAlignment)
    }

    private func nearestSpreadIndex(in collectionView: UICollectionView) -> Int? {
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
