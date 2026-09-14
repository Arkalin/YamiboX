import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var parent: MangaPagedPageCurlReaderViewport
    let informationState = ReaderAttachedInformationState()
    let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
    let interactionRuntime = MangaPagedInteractionRuntime()
    private var selectionResolver = MangaPagedPageCurlSelectionResolver()
    private var contentIdentity: MangaPagedReaderContentIdentity?
    private var currentSelectionIndex: Int?
    private var lastReportedGlobalIndex: Int?
    private(set) var pageSurfaceInteractions: [String: MangaSurfaceAttachment] = [:]
    private var pageCurlSurfaceInteractionIdentity: MangaPagedReaderSurfaceInteractionIdentity?
    private var pageCurlPageAppearanceGenerations: [String: Int] = [:]
    private var lastAppliedLikedPageIDs: Set<String> = []
    weak var activeContainerViewController: MangaPagedPageCurlContainerViewController?
    weak var activePageViewController: UIPageViewController?
    private let controllers = NSHashTable<MangaPagedPageCurlHostingController>.weakObjects()
    private var selectionTransitionID = UUID()
    private var animatedSelectionTransitionID: UUID?
    private var interactivePageCurlTransition: (id: UUID, generation: UInt64)?
    private(set) lazy var gestures = MangaPagedPageCurlNavigationAdapter(coordinator: self)
    private(set) lazy var zoom = MangaPagedPageCurlZoomController(coordinator: self)

    var selectionIndex: Int { currentSelectionIndex ?? parent.selectionIndex }

    var isPageTurnInProgress: Bool {
        animatedSelectionTransitionID != nil || interactivePageCurlTransition != nil
    }

    init(parent: MangaPagedPageCurlReaderViewport) {
        self.parent = parent
        informationState.update(parent.attachedInformation)
    }

    func update(
        _ containerViewController: MangaPagedPageCurlContainerViewController,
        contentIdentity nextContentIdentity: MangaPagedReaderContentIdentity
    ) {
        informationState.update(parent.attachedInformation)
        prefetchAdjacentImages()
        let pageViewController = containerViewController.pageViewController
        activeContainerViewController = containerViewController
        activePageViewController = pageViewController
        let didChangeContentIdentity = contentIdentity != nextContentIdentity
        if didChangeContentIdentity {
            invalidatePageCurlTransitions()
            interactionRuntime.reset(keeping: [SurfaceID(value: "curl-spread")])
            pageSurfaceInteractions = [:]
            pageCurlSurfaceInteractionIdentity = nil
            pageCurlPageAppearanceGenerations = [:]
            zoom.reset()
        }
        contentIdentity = nextContentIdentity
        gestures.configureContainerGestures(in: containerViewController)
        gestures.configureGestures(in: pageViewController)
        let isAwaitingSinglePageSpine = !parent.sequence.usesTwoPageSpread &&
            pageViewController.mangaPageCurlSpineLocation == .mid
        _ = configureSpine(in: pageViewController)
        applyPageBackground(to: pageViewController)
        guard !isAwaitingSinglePageSpine else { return }

        let targetSelectionIndex = selectionResolver.selectionIndex(
            plan: parent.plan,
            viewportPlacement: parent.viewportPlacement
        )
        updateVisiblePageCurlPagesIfNeeded(in: pageViewController)
        guard didChangeContentIdentity || currentSelectionIndex != targetSelectionIndex else {
            return
        }
        setCurrentSelection(
            in: pageViewController,
            selectionIndex: targetSelectionIndex,
            animated: !didChangeContentIdentity && parent.viewportPlacement?.animated == true
        )
    }

    private func updateVisiblePageCurlPagesIfNeeded(in pageViewController: UIPageViewController) {
        let nextIdentity = MangaPagedReaderSurfaceInteractionIdentity(
            isChromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled
        )
        let likedPageIDsChanged = parent.likedPageIDs != lastAppliedLikedPageIDs
        guard nextIdentity != pageCurlSurfaceInteractionIdentity || likedPageIDsChanged else { return }
        let needsContentUpdate = nextIdentity.zoomEnabled != pageCurlSurfaceInteractionIdentity?.zoomEnabled || likedPageIDsChanged
        pageCurlSurfaceInteractionIdentity = nextIdentity
        lastAppliedLikedPageIDs = parent.likedPageIDs
        for surface in pageSurfaceInteractions.values { surface.runtime.setChromeVisible(parent.isChromeVisible) }
        guard needsContentUpdate else { return }

        for case let controller as MangaPagedPageCurlHostingController in pageViewController.viewControllers ?? [] {
            controller.updateRootView(
                rootView(for: controller.leaf, preserving: controller.rootView.pageSurface),
                pageBackgroundColor: parent.pageEdgeFillColor
            )
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let pageController = viewController as? MangaPagedPageCurlHostingController,
              let leafIndex = parent.sequence.leafIndex(before: pageController.leaf) else {
            return nil
        }
        return controller(forLeafIndex: leafIndex)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let pageController = viewController as? MangaPagedPageCurlHostingController,
              let leafIndex = parent.sequence.leafIndex(after: pageController.leaf) else {
            return nil
        }
        return controller(forLeafIndex: leafIndex)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        invalidatePageCurlTransitions()
        refreshBackPages()
        let transitionID = UUID()
        interactivePageCurlTransition = (transitionID, interactionRuntime.navigationGeneration)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation {
        let spineLocation = configureSpine(in: pageViewController)
        setCurrentSelection(in: pageViewController, animated: false)
        return spineLocation
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard let transition = interactivePageCurlTransition else { return }
        interactivePageCurlTransition = nil
        guard completed, interactionRuntime.navigationGeneration == transition.generation else { return }
        preparePreviousPageCurlPagesForReuse(previousViewControllers)
        publishSelection(from: pageViewController)
    }

    func configureSpine(in pageViewController: UIPageViewController) -> UIPageViewController.SpineLocation {
        let configuration = MangaPagedPageCurlSpineConfiguration.configuration(
            usesTwoPageSpread: parent.sequence.usesTwoPageSpread,
            currentSpineLocation: pageViewController.mangaPageCurlSpineLocation
        )
        if let doubleSided = configuration.doubleSidedUpdate {
            pageViewController.isDoubleSided = doubleSided
        }
        return configuration.uiPageViewControllerSpineLocation
    }

    func setCurrentSelection(in pageViewController: UIPageViewController, animated: Bool) {
        let targetSelectionIndex = selectionResolver.selectionIndex(
            plan: parent.plan,
            viewportPlacement: parent.viewportPlacement
        )
        setCurrentSelection(
            in: pageViewController,
            selectionIndex: targetSelectionIndex,
            animated: animated
        )
    }

    func setCurrentSelection(
        in pageViewController: UIPageViewController,
        selectionIndex: Int,
        animated: Bool
    ) {
        setSelection(selectionIndex, in: pageViewController, animated: animated, publishOnCompletion: false)
    }

    func animateAdjacentSelection(delta: Int, in pageViewController: UIPageViewController) {
        // Replacing an unfinished curl invalidates its only page-selection commit.
        guard !isPageTurnInProgress else { return }
        let targetSelectionIndex = selectionIndex + delta
        guard targetSelectionIndex >= 0,
              targetSelectionIndex < parent.sequence.pageCount else {
            return
        }
        setSelection(
            targetSelectionIndex,
            in: pageViewController,
            animated: true,
            publishOnCompletion: true
        )
    }

    private func setSelection(
        _ selectionIndex: Int,
        in pageViewController: UIPageViewController,
        animated: Bool,
        publishOnCompletion: Bool
    ) {
        invalidatePageCurlTransitions()
        refreshBackPages()
        let transitionID = selectionTransitionID
        let clampedSelectionIndex = min(max(selectionIndex, 0), max(parent.sequence.pageCount - 1, 0))
        let leafIndexes = parent.sequence.leafIndexes(forSelectionIndex: clampedSelectionIndex)
        let direction = navigationDirection(to: clampedSelectionIndex)
        // UIKit takes only the visible front for nonanimated single-page placement.
        // A forward curl uses the departing back; a reverse curl uses the arriving back.
        var displayedLeafIndexes = parent.sequence.usesTwoPageSpread || animated
            ? leafIndexes : Array(leafIndexes.prefix(1))
        if animated, !parent.sequence.usesTwoPageSpread, direction == .forward,
           let currentSelectionIndex,
           let backIndex = parent.sequence.leafIndexes(forSelectionIndex: currentSelectionIndex).last,
           displayedLeafIndexes.count == 2 {
            displayedLeafIndexes[1] = backIndex
        }
        let controllers = displayedLeafIndexes.compactMap(controller(forLeafIndex:))
        guard !controllers.isEmpty else {
            currentSelectionIndex = nil
            return
        }
        if clampedSelectionIndex != currentSelectionIndex {
            zoom.runtime.invalidate(reset: true)
            for case let controller as MangaPagedPageCurlHostingController in pageViewController.viewControllers ?? [] {
                // Keep the outgoing single-page crop until its sheet has finished turning.
                if !controller.leaf.isBack, !animated || parent.sequence.usesTwoPageSpread,
                   let pageID = controller.leaf.pageID {
                    pageSurfaceInteractions[pageID]?.runtime.invalidate(reset: true)
                }
            }
        }

        let outgoingViewControllers = pageViewController.viewControllers ?? []
        let shouldPrepareOutgoingPageCurlPages = !parent.sequence.usesTwoPageSpread &&
            clampedSelectionIndex != currentSelectionIndex
        let generation = interactionRuntime.navigationGeneration
        if animated {
            animatedSelectionTransitionID = transitionID
        }
        pageViewController.setViewControllers(
            controllers,
            direction: direction,
            animated: animated
        ) { [weak self] completed in
            guard let self else { return }
            guard self.selectionTransitionID == transitionID else { return }
            self.animatedSelectionTransitionID = nil
            guard self.interactionRuntime.navigationGeneration == generation else { return }
            guard !animated || completed else { return }
            if animated, shouldPrepareOutgoingPageCurlPages {
                self.preparePreviousPageCurlPagesForReuse(outgoingViewControllers)
            }
            self.currentSelectionIndex = clampedSelectionIndex
            if publishOnCompletion {
                self.publishCurrentPageIfNeeded(selectionIndex: clampedSelectionIndex)
            }
        }
        if !animated {
            if shouldPrepareOutgoingPageCurlPages {
                preparePreviousPageCurlPagesForReuse(outgoingViewControllers)
            }
            currentSelectionIndex = clampedSelectionIndex
        }
    }

    private func navigationDirection(to selectionIndex: Int) -> UIPageViewController.NavigationDirection {
        guard let currentSelectionIndex,
              let currentLeafIndex = parent.sequence.firstLeafIndex(forSelectionIndex: currentSelectionIndex),
              let targetLeafIndex = parent.sequence.firstLeafIndex(forSelectionIndex: selectionIndex) else {
            return .forward
        }
        return targetLeafIndex >= currentLeafIndex ? .forward : .reverse
    }

    private func controller(forLeafIndex leafIndex: Int) -> UIViewController? {
        guard parent.sequence.leaves.indices.contains(leafIndex) else { return nil }
        let leaf = parent.sequence.leaves[leafIndex]
        let controller = MangaPagedPageCurlHostingController(
            leaf: leaf,
            rootView: rootView(for: leaf),
            pageBackgroundColor: parent.pageEdgeFillColor
        )
        controllers.add(controller)
        if leaf.isBack {
            controller.onWillAppear = { [weak self, weak controller] in
                guard let self, let controller, !self.isPageTurnInProgress else { return }
                self.refreshBackPage(controller)
            }
        }
        return controller
    }

    private func rootView(
        for leaf: MangaPagedPageCurlLeaf,
        preserving existingSurface: MangaPagedReaderSpreadPageSurface? = nil
    ) -> MangaPagedPageCurlLeafView {
        MangaPagedPageCurlLeafView(
            informationState: informationState,
            informationIndex: leaf.selectionIndex,
            informationSlot: parent.plan.usesTwoPageSpread ? leaf.index % 2 : 0,
            pageSurface: pageSurface(for: leaf, preserving: existingSurface),
            imageLoader: parent.imageLoader,
            pageScaleMode: parent.effectivePageScaleMode,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            zoomEnabled: parent.zoomEnabled,
            isPageZoomEnabled: !parent.sequence.usesTwoPageSpread,
            likedPageIDs: leaf.isBack ? [] : parent.likedPageIDs,
            isBack: leaf.isBack,
            backContent: backContent(for: leaf)
        )
    }

    private func backContent(for leaf: MangaPagedPageCurlLeaf) -> MangaPagedPageCurlBackContent? {
        guard leaf.isBack, let pageIndex = leaf.pageIndex,
              let page = parent.plan.page(at: pageIndex), page.id == leaf.pageID else { return nil }
        let image = parent.imageLoader.cachedImage(for: page)
        let runtime = pageSurfaceInteractions[page.id]?.runtime
        if let runtime, runtime.imageLoaded {
            return MangaPagedPageCurlBackContent(image: image, geometry: runtime.geometry, transform: runtime.transform)
        }
        return MangaPagedPageCurlBackContent(image: image,
            geometry: .image(size: image?.size ?? .zero, viewport: .zero,
                fit: MangaSurfaceFit(parent.effectivePageScaleMode),
                alignment: initialHorizontalAlignment(for: page, pageIndex: pageIndex)),
            transform: MangaSurfaceTransform())
    }

    private func refreshBackPages() {
        for controller in controllers.allObjects where controller.leaf.isBack {
            refreshBackPage(controller)
        }
    }

    private func refreshBackPage(_ controller: MangaPagedPageCurlHostingController) {
        guard let index = parent.sequence.leafIndex(matching: controller.leaf) else { return }
        controller.updateRootView(rootView(for: parent.sequence.leaves[index]), pageBackgroundColor: parent.pageEdgeFillColor)
        controller.view.layoutIfNeeded()
    }

    private func pageSurface(
        for leaf: MangaPagedPageCurlLeaf,
        preserving existingSurface: MangaPagedReaderSpreadPageSurface?
    ) -> MangaPagedReaderSpreadPageSurface? {
        guard !leaf.isBack, let pageIndex = leaf.pageIndex,
              let page = parent.plan.page(at: pageIndex) else {
            return nil
        }
        let identity = pageCurlPageSurfaceIdentity(for: page)
        let interaction = surfaceInteraction(for: page)
        // Chrome/like refreshes must not reinterpret a backward entry after selection catches up.
        let alignment = existingSurface.flatMap { surface in
            surface.surfaceIdentity == identity && surface.surfaceInteraction === interaction
                ? surface.initialHorizontalAlignment : nil
        } ?? initialHorizontalAlignment(for: page, pageIndex: pageIndex)
        return MangaPagedReaderSpreadPageSurface(
            page: page,
            surfaceIdentity: identity,
            initialHorizontalAlignment: alignment,
            surfaceInteraction: interaction,
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

    private func prefetchAdjacentImages() {
        let pagesToPrefetch = MangaPagedImagePrefetchPlan.pagesToPrefetch(plan: parent.plan)
        parent.imageLoader.prefetchImages(for: pagesToPrefetch)
    }

    private func pageCurlPageSurfaceIdentity(
        for page: MangaReaderPageProjection
    ) -> MangaPagedReaderPageAppearanceIdentity {
        MangaPagedReaderPageAppearanceIdentity(
            pageID: page.id,
            appearanceGeneration: pageCurlPageAppearanceGenerations[page.id, default: 0]
        )
    }

    private func initialHorizontalAlignment(
        for page: MangaReaderPageProjection,
        pageIndex: Int
    ) -> MangaPagedImageSurfaceInitialHorizontalAlignment {
        MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: parent.settings.pageTurnDirection,
            pageScaleMode: parent.effectivePageScaleMode,
            currentPageIndex: parent.plan.currentPageIndex,
            targetPageIndex: pageIndex
        )
    }

    private func surfaceInteraction(for page: MangaReaderPageProjection) -> MangaSurfaceAttachment {
        if let interaction = pageSurfaceInteractions[page.id] {
            return interaction
        }
        let interaction = MangaSurfaceAttachment(runtime: interactionRuntime.surface(SurfaceID(value: "page:" + page.id)))
        interaction.runtime.setChromeVisible(parent.isChromeVisible)
        interaction.runtime.permitsInteraction = { [weak self] in self?.isPageTurnInProgress == false }
        pageSurfaceInteractions[page.id] = interaction
        return interaction
    }

    func applyPageBackground(to containerViewController: MangaPagedPageCurlContainerViewController) {
        let pageBackgroundColor = parent.pageEdgeFillColor
        containerViewController.view.backgroundColor = pageBackgroundColor
        containerViewController.view.isOpaque = true
        applyPageBackground(to: containerViewController.pageViewController)
    }

    private func applyPageBackground(to pageViewController: UIPageViewController) {
        let pageBackgroundColor = parent.pageEdgeFillColor
        pageViewController.view.backgroundColor = pageBackgroundColor
        pageViewController.view.isOpaque = true
        for case let controller as MangaPagedPageCurlHostingController in pageViewController.viewControllers ?? [] {
            controller.applyPageBackground(pageBackgroundColor)
        }
    }

    func invalidatePageCurlTransitions() {
        selectionTransitionID = UUID()
        animatedSelectionTransitionID = nil
        interactivePageCurlTransition = nil
    }

    private func publishSelection(from pageViewController: UIPageViewController) {
        let leafIndexes = pageViewController.viewControllers?
            .compactMap { ($0 as? MangaPagedPageCurlHostingController)?.leaf.index } ?? []
        guard let selectionIndex = parent.sequence.selectionIndex(forLeafIndexes: leafIndexes) else { return }
        if parent.sequence.usesTwoPageSpread, selectionIndex != currentSelectionIndex {
            zoom.reset()
        }
        currentSelectionIndex = selectionIndex
        guard selectionIndex != parent.selectionIndex else { return }
        publishCurrentPageIfNeeded(selectionIndex: selectionIndex)
    }

    private func preparePreviousPageCurlPagesForReuse(_ previousViewControllers: [UIViewController]) {
        guard !parent.sequence.usesTwoPageSpread else { return }
        for case let controller as MangaPagedPageCurlHostingController in previousViewControllers {
            guard !controller.leaf.isBack, let pageIndex = controller.leaf.pageIndex,
                  let page = parent.plan.page(at: pageIndex) else {
                continue
            }
            pageCurlPageAppearanceGenerations[page.id, default: 0] += 1
            controller.updateRootView(rootView(for: controller.leaf), pageBackgroundColor: parent.pageEdgeFillColor)
        }
    }

    private func publishCurrentPageIfNeeded(selectionIndex: Int) {
        guard let globalIndex = parent.sequence.globalIndex(forSelectionIndex: selectionIndex),
              globalIndex != lastReportedGlobalIndex else {
            return
        }

        lastReportedGlobalIndex = globalIndex
        if parent.sequence.usesTwoPageSpread {
            interactionRuntime.activate(SurfaceID(value: "curl-spread"))
        } else if let page = parent.plan.spread(at: selectionIndex)?.preferredPage {
            interactionRuntime.activate(SurfaceID(value: "page:" + page.id))
        }
        let onCurrentPageChange = parent.onCurrentPageChange
        callbackScheduler.publish {
            onCurrentPageChange(globalIndex)
        }
    }
}

private extension UIPageViewController {
    var mangaPageCurlSpineLocation: MangaPagedPageCurlSpineLocation {
        spineLocation == .mid ? .mid : .min
    }
}

private extension MangaPagedPageCurlSpineConfiguration {
    var uiPageViewControllerSpineLocation: UIPageViewController.SpineLocation {
        switch spineLocation {
        case .min:
            .min
        case .mid:
            .mid
        }
    }
}
#endif
