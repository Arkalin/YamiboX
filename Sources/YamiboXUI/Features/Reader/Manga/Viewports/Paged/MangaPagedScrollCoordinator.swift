import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedScrollCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {
    static let reuseIdentifier = "MangaPagedReaderPageCell"

    private struct Turn {
        let id = UUID()
        let target: Int
        let reason: Landing
        let effect: MangaPagedTransitionDriver.Effect
    }

    private enum Landing {
        case initial(placementRevision: Int?)
        case placement(revision: Int)
        case navigation
    }

    private struct PagingState {
        enum Owner {
            case none
            case image
            case native(source: Int, candidate: Int, boundary: Int? = nil)
            case discrete(effect: MangaPagedTransitionDriver.Effect)
            case transition(Turn)
        }

        var owner: Owner = .none
        var anchor: Int?
        var needsInitialPlacement = false
        var handledPlacementRevision: Int?
        var pendingTurn: Turn?
        var publicationGeneration: UInt64 = 0
    }

    var parent: MangaPagedReaderViewport
    let informationState = ReaderAttachedInformationState()
    let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
    private let transitionDriver = MangaPagedTransitionDriver()
    private(set) lazy var interactionRuntime = MangaPagedInteractionRuntime(zoomSession: parent.pagedZoom) { [weak self] in
        self?.parent.settings.zoomAnimationEnabled ?? true
    }
    private var contentIdentity: MangaPagedReaderContentIdentity?
    private var surfaceInteractionIdentity: MangaPagedReaderSurfaceInteractionIdentity?
    private var pageSurfaceInteractions: [String: MangaSurfaceAttachment] = [:]
    private var spreadSurfaceInteractions: [String: MangaSurfaceAttachment] = [:]
    private var lastAppliedLikedPageIDs: Set<String> = []
    private var lastLaidOutViewportSize: CGSize?
    private weak var collectionView: MangaPagedReaderCollectionView?
    private var paging = PagingState()
    private var settlementLink: CADisplayLink?
    private var nativePanAdmitted = false
    private var isCorrectingOffset = false
    private var isReplacingContent = false
    private var isStartingTurn = false
    private let imagePrefetch: MangaPagedImagePrefetchSession
    private(set) lazy var gestures = MangaPagedScrollNavigationAdapter(coordinator: self)

    private var unappliedPlacement: MangaNovelReaderViewportPlacement? {
        guard let placement = parent.viewportPlacement,
              placement.revision != paging.handledPlacementRevision else { return nil }
        return placement
    }

    private var turnEffect: MangaPagedTransitionDriver.Effect {
        switch parent.settings.pagedTurnStyle {
        case .slide: .slide
        case .quickFade: .quickFade
        case .none, .pageCurl: .cut
        }
    }
    init(parent: MangaPagedReaderViewport) {
        self.parent = parent
        imagePrefetch = MangaPagedImagePrefetchSession(loader: parent.imageLoader)
    }

    func attach(to collectionView: MangaPagedReaderCollectionView) {
        self.collectionView = collectionView
    }

    func detachViewport() {
        let collection = collectionView
        collectionView = nil
        resetPaging()
        if let collection { transitionDriver.cancel(in: collection) }
        stopImagePrefetch()
        interactionRuntime.reset()
    }

    func updateContentIfNeeded(in collection: UICollectionView) {
        informationState.update(parent.attachedInformation)
        prefetchAdjacentImages()
        let nextIdentity = MangaPagedReaderContentIdentity(
            spreadIDs: parent.plan.spreadIDs,
            pageScaleMode: parent.effectivePageScaleMode,
            pageTurnDirection: parent.settings.pageTurnDirection,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            colorScheme: parent.colorScheme
        )
        if nextIdentity != contentIdentity {
            isReplacingContent = true
            contentIdentity = nextIdentity
            resetPaging()
            transitionDriver.cancel(in: collection)
            interactionRuntime.reset()
            surfaceInteractionIdentity = nil
            pageSurfaceInteractions.removeAll()
            spreadSurfaceInteractions.removeAll()
            lastLaidOutViewportSize = nil
            paging.needsInitialPlacement = !parent.plan.spreads.isEmpty
            collection.alpha = paging.needsInitialPlacement ? 0 : 1
            collection.collectionViewLayout.invalidateLayout()
            collection.reloadData()
            isReplacingContent = false
            collection.setNeedsLayout()
            collection.layoutIfNeeded()
        }
        transitionDriver.updateBaseColor(parent.pageEdgeFillColor, in: collection)
        updateGestureState(in: collection)
        reconcilePaging()
        updateVisiblePageSurfacesIfNeeded(in: collection)
    }

    func didLayoutViewport(_ collection: UICollectionView) {
        let size = collection.bounds.size
        if let previous = lastLaidOutViewportSize, size != previous {
            switch paging.owner {
            case .transition:
                // An explicit request remains pending; a local turn returns to its anchor.
                paging.owner = .none
                transitionDriver.cancel(in: collection)
            case .native:
                // Keep the admitted drag alive across layout changes.
                break
            default:
                transitionDriver.cancel(in: collection)
            }
        }
        lastLaidOutViewportSize = size
        reconcilePaging()
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
        guard let collection = collectionView, scrollView === collection, let anchor = paging.anchor else { return }
        // A recognizer may get to its delegate while a layout or an image callback
        // is on the stack. Only a pan admitted by the adapter may start a turn.
        guard nativePanAdmitted, case .none = paging.owner, unappliedPlacement == nil else {
            nativePanAdmitted = false
            reconcilePaging()
            return
        }
        nativePanAdmitted = false
        paging.owner = .native(source: anchor, candidate: anchor)
        for path in collection.indexPathsForVisibleItems {
            preparePageEntry(at: spreadIndex(forViewportIndex: path.item))
        }
        transitionDriver.beginSlideVisuals(from: viewportIndex(forSpreadIndex: anchor), in: collection)
        observeSettlement()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let collection = collectionView, scrollView === collection, !isCorrectingOffset else { return }
        switch paging.owner {
        case let .native(source, candidate, boundary):
            let next = geometricLanding(in: collection) ?? candidate
            paging.owner = .native(source: source, candidate: next, boundary: boundary)
            transitionDriver.updateSlideVisuals(in: collection)
        case .transition:
            transitionDriver.updateSlideVisuals(in: collection)
        default:
            reconcilePaging()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let collection = collectionView, scrollView === collection,
              case let .native(source, candidate, _) = paging.owner else { return }
        let pan = collection.panGestureRecognizer
        let delta = pan.state == .cancelled || unappliedPlacement != nil ? nil : ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: source,
            itemCount: parent.plan.spreads.count,
            translation: pan.translation(in: collection),
            velocity: pan.velocity(in: collection),
            viewportWidth: collection.bounds.width,
            horizontalNavigationDirection: parent.settings.pageTurnDirection.horizontalNavigationDirection
        )
        paging.owner = .native(source: source, candidate: candidate, boundary: delta)
        if !decelerate || unappliedPlacement != nil { reconcilePaging() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reconcilePaging()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // A UIKit offset change alone is not a navigation command.
        reconcilePaging()
    }

    var currentSpreadIndex: Int? { paging.anchor }

    func canBeginPagePan(in collection: UICollectionView) -> Bool {
        reconcilePaging()
        guard case .none = paging.owner, paging.anchor != nil,
              unappliedPlacement == nil, paging.pendingTurn == nil, !paging.needsInitialPlacement,
              !collection.isDragging, !collection.isDecelerating else { return false }
        let image = paging.anchor.flatMap(surface(forSpreadAt:))?.imageInteractionState
        return image.map { !$0.isMoving && !MangaPageZoomPolicy.isActive($0.factor) } ?? true
    }

    func admitNativePan() {
        nativePanAdmitted = true
    }

    func beginDiscretePan() {
        guard case .none = paging.owner, unappliedPlacement == nil else { return }
        paging.owner = .discrete(effect: turnEffect)
    }

    func finishDiscretePan(delta: Int?) {
        guard case let .discrete(effect) = paging.owner, let collection = collectionView else { return }
        paging.owner = .none
        if let delta, let step = NavigationStep(rawValue: delta) {
            navigate(step, effect: effect)
        }
        updateGestureState(in: collection)
        reconcilePaging()
    }

    var acceptsNavigationInput: Bool {
        guard unappliedPlacement == nil, !paging.needsInitialPlacement else { return false }
        switch paging.owner {
        case .none, .image: return paging.anchor != nil
        default: return false
        }
    }

    func navigate(_ step: NavigationStep) {
        navigate(step, effect: turnEffect)
    }

    private func navigate(_ step: NavigationStep, effect: MangaPagedTransitionDriver.Effect) {
        guard acceptsNavigationInput, let anchor = paging.anchor, paging.pendingTurn == nil else { return }
        let target = anchor + step.rawValue
        guard parent.plan.spreads.indices.contains(target) else {
            publishBoundary(step.rawValue)
            return
        }
        paging.pendingTurn = Turn(target: target, reason: .navigation, effect: effect)
        reconcilePaging()
    }

    private func publishBoundary(_ delta: Int) {
        let generation = paging.publicationGeneration
        let revision = parent.viewportPlacement?.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.collectionView != nil, self.paging.publicationGeneration == generation,
                  self.parent.viewportPlacement?.revision == revision, self.unappliedPlacement == nil else { return }
            if self.parent.canBoundaryPageTurn(delta) {
                self.parent.onBoundaryPageTurn(delta)
            } else {
                self.parent.onBoundaryPageTurnRejected(delta)
            }
        }
    }

    func updateGestureState(in collection: UICollectionView) {
        // Changing UIKit's isEnabled during a gesture cancels it. Use the new
        // effect only after ownership has returned from an admitted pan.
        switch paging.owner {
        case .native, .discrete: return
        default: break
        }
        let discrete = parent.settings.pagedTurnStyle.usesDiscretePageTurns
        if collection.panGestureRecognizer.isEnabled == discrete {
            collection.panGestureRecognizer.isEnabled = !discrete
        }
        if gestures.discretePagePanGesture.isEnabled != discrete {
            gestures.discretePagePanGesture.isEnabled = discrete
        }
    }

    @objc private func reconcilePaging() {
        guard let collection = collectionView, !isReplacingContent, !isCorrectingOffset, !isStartingTurn else { return }

        if paging.needsInitialPlacement {
            guard let target = unappliedPlacement.flatMap(spreadIndex(for:)) ?? parent.plan.currentSpreadIndex
                    ?? parent.plan.spreads.indices.first else { return }
            startTurn(Turn(target: target, reason: .initial(placementRevision: unappliedPlacement?.revision),
                           effect: .cut), in: collection)
            return
        }

        if let placement = unappliedPlacement, let target = spreadIndex(for: placement) {
            if case let .transition(turn) = paging.owner,
               case let .placement(revision) = turn.reason, revision == placement.revision { return }
            if case .transition = paging.owner {
                paging.owner = .none
                transitionDriver.cancel(in: collection)
            }
            paging.pendingTurn = nil
            guard !hasActivePan(collection.panGestureRecognizer), !collection.isDragging else { return }
            guard alignedOffsetX(for: target, in: collection) != nil else {
                stopSettlementObservation()
                return
            }
            paging.owner = .none
            stopSettlementObservation()
            transitionDriver.cancel(in: collection)
            let effect: MangaPagedTransitionDriver.Effect = placement.animated && collection.window != nil ? turnEffect : .cut
            startTurn(Turn(target: target, reason: .placement(revision: placement.revision), effect: effect), in: collection)
            return
        }

        guard let anchor = paging.anchor else { return }
        switch paging.owner {
        case .transition:
            return
        case let .native(_, candidate, boundary):
            guard !hasActivePan(collection.panGestureRecognizer), !collection.isDragging,
                  !collection.isDecelerating, !collection.isScrollAnimating else {
                observeSettlement()
                return
            }
            guard let x = alignedOffsetX(for: candidate, in: collection) else {
                stopSettlementObservation()
                return
            }
            guard !collection.isTracking || isAligned(to: x, in: collection) else {
                observeSettlement()
                return
            }
            guard align(to: x, in: collection) else { observeSettlement(); return }
            transitionDriver.endSlideVisuals(in: collection)
            land(at: candidate, reason: .navigation, in: collection)
            if let boundary { publishBoundary(boundary) }
        case .discrete:
            // Recognition has no authority over the outer offset until it
            // produces a navigation target at release.
            if let x = alignedOffsetX(for: anchor, in: collection) { _ = align(to: x, in: collection) }
        case .none, .image:
            if let turn = paging.pendingTurn, startTurn(turn, in: collection) { return }
            let image = surface(forSpreadAt: anchor)?.imageInteractionState
            if image?.isMoving == true { paging.owner = .image }
            guard let x = alignedOffsetX(for: anchor, in: collection) else {
                stopSettlementObservation()
                return
            }
            let aligned = align(to: x, in: collection)
            let imageIsUnfinished = if case .image = paging.owner {
                image?.isMoving == true || image?.hasTouch == true
            } else { false }
            if !aligned || imageIsUnfinished {
                observeSettlement()
                return
            }
            paging.owner = .none
            stopSettlementObservation()
        }
    }

    private func geometricLanding(in collection: UICollectionView) -> Int? {
        guard collection.bounds.size == lastLaidOutViewportSize, collection.bounds.width > 0,
              collection.bounds.height > 0,
              let path = collection.indexPathForItem(at: CGPoint(x: collection.bounds.midX, y: collection.bounds.midY))
              else { return nil }
        let spread = spreadIndex(forViewportIndex: path.item)
        return alignedOffsetX(for: spread, in: collection) != nil ? spread : nil
    }

    private func alignedOffsetX(for spreadIndex: Int, in collection: UICollectionView) -> CGFloat? {
        let size = collection.bounds.size
        guard size.width > 0, size.height > 0, size == lastLaidOutViewportSize,
              parent.plan.spreads.indices.contains(spreadIndex),
              collection.numberOfSections > 0 else { return nil }
        let item = viewportIndex(forSpreadIndex: spreadIndex)
        let tolerance = alignmentTolerance(in: collection)
        guard collection.numberOfItems(inSection: 0) > item,
              let frame = collection.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame,
              abs(frame.width - size.width) <= tolerance, abs(frame.height - size.height) <= tolerance else { return nil }
        let x = frame.midX - size.width / 2
        let insets = collection.adjustedContentInset
        let minX = -insets.left
        let maxX = max(minX, collection.contentSize.width - size.width + insets.right)
        guard x >= minX - tolerance, x <= maxX + tolerance else { return nil }
        return min(max(x, minX), maxX)
    }

    private func alignmentTolerance(in collection: UICollectionView) -> CGFloat {
        0.5 / max(collection.traitCollection.displayScale, 1)
    }

    private func isAligned(to x: CGFloat, in collection: UICollectionView) -> Bool {
        abs(collection.contentOffset.x - x) <= alignmentTolerance(in: collection)
    }

    private func align(to x: CGFloat, in collection: UICollectionView) -> Bool {
        guard !isAligned(to: x, in: collection) else { return true }
        isCorrectingOffset = true
        defer { isCorrectingOffset = false }
        UIView.performWithoutAnimation {
            if collection.isDecelerating || collection.isScrollAnimating { collection.stopScrollingAndZooming() }
            collection.setContentOffset(CGPoint(x: x, y: collection.contentOffset.y), animated: false)
        }
        return isAligned(to: x, in: collection)
    }

    @discardableResult
    private func startTurn(_ turn: Turn, in collection: UICollectionView) -> Bool {
        guard let x = alignedOffsetX(for: turn.target, in: collection) else { return false }
        // Install ownership before any synchronous UIKit offset/layout callback.
        paging.owner = .transition(turn)
        paging.pendingTurn = nil
        stopSettlementObservation()
        isStartingTurn = true
        defer { isStartingTurn = false }
        if collection.isDecelerating || collection.isScrollAnimating {
            collection.stopScrollingAndZooming()
        }
        preparePageEntry(at: turn.target)
        transitionDriver.start(id: turn.id, effect: turn.effect,
                               sourceItem: viewportIndex(forSpreadIndex: paging.anchor ?? turn.target),
                               offsetX: x, in: collection) { [weak self, weak collection] id, event in
            guard let self, let collection, self.collectionView === collection else { return }
            self.handleTransitionEvent(event, id: id, in: collection)
        }
        return true
    }

    private func handleTransitionEvent(_ event: MangaPagedTransitionDriver.Event, id: UUID, in collection: UICollectionView) {
        guard case let .transition(turn) = paging.owner, turn.id == id else { return }
        switch event {
        case .landed:
            let isCurrent: Bool
            switch turn.reason {
            case let .initial(revision): isCurrent = revision == unappliedPlacement?.revision
            case let .placement(revision): isCurrent = revision == unappliedPlacement?.revision
            case .navigation: isCurrent = unappliedPlacement == nil
            }
            guard isCurrent, let x = alignedOffsetX(for: turn.target, in: collection), isAligned(to: x, in: collection) else {
                paging.owner = .none
                collection.setNeedsLayout()
                return
            }
            land(at: turn.target, reason: turn.reason, in: collection)
        case .cancelled, .finished:
            // Still owned here means the turn did not land. Explicit placement
            // stays outstanding; an adjacent turn returns to its prior anchor.
            paging.owner = .none
            collection.setNeedsLayout()
        }
    }

    private func land(at index: Int, reason: Landing, in collection: UICollectionView) {
        let changedAnchor = paging.anchor != index
        paging.anchor = index
        paging.owner = .none
        stopSettlementObservation()
        switch reason {
        case let .initial(revision):
            paging.publicationGeneration &+= 1
            paging.needsInitialPlacement = false
            paging.handledPlacementRevision = revision
            collection.alpha = 1
        case let .placement(revision):
            paging.publicationGeneration &+= 1
            paging.handledPlacementRevision = revision
        case .navigation:
            if changedAnchor { paging.publicationGeneration &+= 1 }
        }
        activatePageEntry(at: index)
        updateGestureState(in: collection)
        guard case .navigation = reason, changedAnchor,
              let globalIndex = parent.plan.globalIndex(forSpreadAt: index) else { return }
        let generation = paging.publicationGeneration
        let revision = parent.viewportPlacement?.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.collectionView != nil, self.paging.publicationGeneration == generation,
                  self.parent.viewportPlacement?.revision == revision, self.unappliedPlacement == nil else { return }
            self.parent.onCurrentPageChange(globalIndex)
        }
    }

    private func spreadIndex(for placement: MangaNovelReaderViewportPlacement) -> Int? {
        parent.plan.clampedPageIndex(placement.targetPageIndex).flatMap(parent.plan.spreadIndex(forPageAt:))
    }

    private func hasActivePan(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.state == .began || pan.state == .changed
    }

    private func observeSettlement() {
        guard settlementLink == nil, collectionView?.window != nil else { return }
        let target = SettlementTarget(coordinator: self)
        let link = CADisplayLink(target: target, selector: #selector(SettlementTarget.tick))
        settlementLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopSettlementObservation() {
        settlementLink?.invalidate()
        settlementLink = nil
    }

    private func resetPaging() {
        stopSettlementObservation()
        nativePanAdmitted = false
        paging = PagingState(publicationGeneration: paging.publicationGeneration &+ 1)
    }

    @MainActor
    private final class SettlementTarget: NSObject {
        weak var coordinator: MangaPagedScrollCoordinator?

        init(coordinator: MangaPagedScrollCoordinator) { self.coordinator = coordinator }

        @objc func tick() { coordinator?.reconcilePaging() }
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
            handoff: parent.handoff,
            remoteInput: parent.remoteInput,
            deviceInteraction: parent.deviceInteraction
        )
        cell.resetPageTurnVisuals()
    }

    private func prefetchAdjacentImages() {
        imagePrefetch.update(plan: parent.plan, loader: parent.imageLoader)
    }

    private func stopImagePrefetch() {
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
        observeImageInteraction(in: interaction.runtime)
        pageSurfaceInteractions[page.id] = interaction
        return interaction
    }

    private func spreadSurfaceInteraction(for spread: MangaPageSpread) -> MangaSurfaceAttachment {
        if let interaction = spreadSurfaceInteractions[spread.id] {
            return interaction
        }
        let interaction = MangaSurfaceAttachment(runtime: interactionRuntime.surface(SurfaceID(value: "spread:" + spread.id)))
        interaction.runtime.setChromeVisible(parent.isChromeVisible)
        observeImageInteraction(in: interaction.runtime)
        spreadSurfaceInteractions[spread.id] = interaction
        return interaction
    }

    private func observeImageInteraction(in runtime: MangaSurfaceRuntime) {
        runtime.permitsInteraction = { [weak self] in self?.acceptsNavigationInput == true }
        runtime.onImageInteractionChange = { [weak self, weak runtime] in
            guard let self, let runtime, let anchor = self.paging.anchor,
                  self.surface(forSpreadAt: anchor) === runtime else { return }
            self.callbackScheduler.performViewUpdate { self.reconcilePaging() }
        }
    }

    func surface(forSpreadAt spreadIndex: Int) -> MangaSurfaceRuntime? {
        guard let spread = parent.plan.spread(at: spreadIndex) else { return nil }
        return parent.plan.usesTwoPageSpread
            ? spreadSurfaceInteractions[spread.id]?.runtime
            : pageSurfaceInteractions[spread.preferredPage.id]?.runtime
    }

    private func surfaceID(for spread: MangaPageSpread) -> SurfaceID {
        SurfaceID(value: parent.plan.usesTwoPageSpread ? "spread:" + spread.id : "page:" + spread.preferredPage.id)
    }

    private var pageEntryAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment {
        .init(pageTurnDirection: parent.settings.pageTurnDirection)
    }

    private func preparePageEntry(at index: Int) {
        guard let spread = parent.plan.spread(at: index) else { return }
        interactionRuntime.prepare(surfaceID(for: spread), alignment: pageEntryAlignment)
    }

    private func activatePageEntry(at index: Int) {
        guard let spread = parent.plan.spread(at: index) else { return }
        interactionRuntime.activate(surfaceID(for: spread), selectionID: spread.id, alignment: pageEntryAlignment)
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
