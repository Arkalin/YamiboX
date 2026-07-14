import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedPageCurlCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var parent: MangaPagedPageCurlReaderViewport
    let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
    private var selectionResolver = MangaPagedPageCurlSelectionResolver()
    private var contentIdentity: MangaPagedReaderContentIdentity?
    private var currentSelectionIndex: Int?
    private var lastReportedGlobalIndex: Int?
    private(set) var pageSurfaceInteractions: [String: MangaPagedReaderPageSurfaceInteraction] = [:]
    private var pageCurlSurfaceInteractionIdentity: MangaPagedReaderSurfaceInteractionIdentity?
    private var pageCurlPageAppearanceGenerations: [String: Int] = [:]
    private var lastAppliedLikedPageIDs: Set<String> = []
    weak var activeContainerViewController: MangaPagedPageCurlContainerViewController?
    weak var activePageViewController: UIPageViewController?
    private weak var pageCurlBackColorPageViewController: UIPageViewController?
    private var pageCurlBackColorDisplayLink: CADisplayLink?
    private let pageCurlBackColorFilterCache = MangaPageCurlBackColorFilterCache()
    private(set) lazy var gestures = MangaPagedPageCurlGestureController(coordinator: self)
    private(set) lazy var zoom = MangaPagedPageCurlZoomController(coordinator: self)

    init(parent: MangaPagedPageCurlReaderViewport) {
        self.parent = parent
    }

    deinit {
        MainActor.assumeIsolated {
            stopPageCurlBackColorRefresh()
        }
    }

    func update(
        _ containerViewController: MangaPagedPageCurlContainerViewController,
        contentIdentity nextContentIdentity: MangaPagedReaderContentIdentity
    ) {
        prefetchAdjacentImages()
        let pageViewController = containerViewController.pageViewController
        activeContainerViewController = containerViewController
        activePageViewController = pageViewController
        let didChangeContentIdentity = contentIdentity != nextContentIdentity
        if didChangeContentIdentity {
            pageSurfaceInteractions = [:]
            pageCurlSurfaceInteractionIdentity = nil
            pageCurlPageAppearanceGenerations = [:]
            zoom.resetPageCurlSpreadZoom(in: containerViewController, animated: false)
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
        pageCurlSurfaceInteractionIdentity = nextIdentity
        lastAppliedLikedPageIDs = parent.likedPageIDs

        for case let controller as MangaPagedPageCurlHostingController in pageViewController.viewControllers ?? [] {
            controller.updateRootView(rootView(for: controller.leaf), pageBackgroundColor: parent.pageEdgeFillColor)
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
        startPageCurlBackColorRefresh(in: pageViewController)
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
        stopPageCurlBackColorRefresh()
        guard completed else { return }
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
        let currentSelectionIndex = currentSelectionIndex ?? parent.selectionIndex
        let targetSelectionIndex = currentSelectionIndex + delta
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
        let clampedSelectionIndex = min(max(selectionIndex, 0), max(parent.sequence.pageCount - 1, 0))
        let leafIndexes = parent.sequence.leafIndexes(forSelectionIndex: clampedSelectionIndex)
        let controllers = leafIndexes.compactMap(controller(forLeafIndex:))
        guard !controllers.isEmpty else {
            currentSelectionIndex = nil
            return
        }
        if parent.sequence.usesTwoPageSpread,
           clampedSelectionIndex != currentSelectionIndex,
           let activeContainerViewController {
            zoom.resetPageCurlSpreadZoom(in: activeContainerViewController, animated: false)
        }

        let direction = navigationDirection(to: clampedSelectionIndex)
        let outgoingViewControllers = pageViewController.viewControllers ?? []
        let shouldPrepareOutgoingPageCurlPages = !parent.sequence.usesTwoPageSpread &&
            clampedSelectionIndex != currentSelectionIndex
        pageViewController.setViewControllers(
            controllers,
            direction: direction,
            animated: animated
        ) { [weak self] completed in
            guard let self else { return }
            if animated {
                self.stopPageCurlBackColorRefresh()
            }
            guard !animated || completed else { return }
            if animated, shouldPrepareOutgoingPageCurlPages {
                self.preparePreviousPageCurlPagesForReuse(outgoingViewControllers)
            }
            self.currentSelectionIndex = clampedSelectionIndex
            if publishOnCompletion {
                self.publishCurrentPageIfNeeded(selectionIndex: clampedSelectionIndex)
            }
        }
        if animated {
            startPageCurlBackColorRefresh(in: pageViewController)
        } else {
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
        return MangaPagedPageCurlHostingController(
            leaf: leaf,
            rootView: rootView(for: leaf),
            pageBackgroundColor: parent.pageEdgeFillColor
        )
    }

    private func rootView(for leaf: MangaPagedPageCurlLeaf) -> MangaPagedPageCurlLeafView {
        MangaPagedPageCurlLeafView(
            pageSurface: pageSurface(for: leaf),
            imageLoader: parent.imageLoader,
            pageScaleMode: parent.effectivePageScaleMode,
            pageEdgeFillStyle: parent.settings.pageEdgeFillStyle,
            isChromeVisible: parent.isChromeVisible,
            zoomEnabled: parent.zoomEnabled,
            isPageZoomEnabled: !parent.sequence.usesTwoPageSpread,
            likedPageIDs: parent.likedPageIDs
        )
    }

    private func pageSurface(for leaf: MangaPagedPageCurlLeaf) -> MangaPagedReaderSpreadPageSurface? {
        guard let pageIndex = leaf.pageIndex,
              let page = parent.plan.page(at: pageIndex) else {
            return nil
        }
        return MangaPagedReaderSpreadPageSurface(
            page: page,
            surfaceIdentity: pageCurlPageSurfaceIdentity(for: page),
            initialHorizontalAlignment: initialHorizontalAlignment(for: page, pageIndex: pageIndex),
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

    private func surfaceInteraction(for page: MangaReaderPageProjection) -> MangaPagedReaderPageSurfaceInteraction {
        if let interaction = pageSurfaceInteractions[page.id] {
            return interaction
        }
        let interaction = MangaPagedReaderPageSurfaceInteraction()
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
        if !parent.sequence.usesTwoPageSpread {
            MangaPageCurlPrivateBackColor.apply(
                to: pageViewController.view,
                backColor: pageBackgroundColor,
                cache: pageCurlBackColorFilterCache
            )
        }
    }

    private func startPageCurlBackColorRefresh(in pageViewController: UIPageViewController) {
        guard !parent.sequence.usesTwoPageSpread else {
            applyPageBackground(to: pageViewController)
            return
        }

        pageCurlBackColorFilterCache.reset()
        pageCurlBackColorPageViewController = pageViewController
        applyPageBackground(to: pageViewController)
        guard pageCurlBackColorDisplayLink == nil else { return }

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(refreshPageCurlBackColor)
        )
        displayLink.add(to: .main, forMode: .common)
        pageCurlBackColorDisplayLink = displayLink
    }

    private func stopPageCurlBackColorRefresh() {
        pageCurlBackColorDisplayLink?.invalidate()
        pageCurlBackColorDisplayLink = nil
        if let pageCurlBackColorPageViewController {
            applyPageBackground(to: pageCurlBackColorPageViewController)
        }
        pageCurlBackColorPageViewController = nil
    }

    @objc
    private func refreshPageCurlBackColor() {
        guard let pageViewController = pageCurlBackColorPageViewController else {
            stopPageCurlBackColorRefresh()
            return
        }
        applyPageBackground(to: pageViewController)
    }

    private func publishSelection(from pageViewController: UIPageViewController) {
        let leafIndexes = pageViewController.viewControllers?
            .compactMap { ($0 as? MangaPagedPageCurlHostingController)?.leaf.index } ?? []
        guard let selectionIndex = parent.sequence.selectionIndex(forLeafIndexes: leafIndexes) else { return }
        if parent.sequence.usesTwoPageSpread,
           selectionIndex != currentSelectionIndex,
           let activeContainerViewController {
            zoom.resetPageCurlSpreadZoom(in: activeContainerViewController, animated: false)
        }
        currentSelectionIndex = selectionIndex
        guard selectionIndex != parent.selectionIndex else { return }
        publishCurrentPageIfNeeded(selectionIndex: selectionIndex)
    }

    private func preparePreviousPageCurlPagesForReuse(_ previousViewControllers: [UIViewController]) {
        guard !parent.sequence.usesTwoPageSpread else { return }
        for case let controller as MangaPagedPageCurlHostingController in previousViewControllers {
            guard let pageIndex = controller.leaf.pageIndex,
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
