#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged navigation completion integration")
struct MangaNavigationLifecycleUIKitTests {
    @Test func noAnimationPlacementFallbackDoesNotStartNativeScrolling() throws {
        let plan = MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)
        let parent = MangaPagedReaderViewport(plan: plan,
            viewportPlacement: MangaNovelReaderViewportPlacement(targetPageIndex: 0, animated: true, revision: 1),
            settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .none),
            imageLoader: loader(), isChromeVisible: false, zoomEnabled: true, likedPageIDs: [],
            controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: { _ in },
            canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in },
            onPageLongPress: { _ in }, onTap: {})
        let owner = parent.makeCoordinator()
        let collection = PlacementCollection(frame: CGRect(x: 0, y: 0, width: 400, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout())
        // A detached collection cannot yet accept the driver's placement.
        owner.applyViewportPlacementIfNeeded(in: collection)
        #expect(collection.animatedPlacements == [false])
    }

    @Test(arguments: [ReaderPagedTurnStyle.none, .quickFade, .pageCurl], ["none", "generation", "chrome", "cancel", "detach"])
    func installedPanKeepsAdmissionUntilCompletion(style: ReaderPagedTurnStyle, invalidation: String) throws {
        var boundaries: [Int] = []
        let plan = MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)
        let pan = EventPan()
        let input = MangaNavigationInput(navigationPan: pan)
        let settings = MangaReaderSettings(readingMode: .paged, pagedTurnStyle: style, pageTurnDirection: .leftToRight)
        let adapter: AnyObject
        let coordinator: AnyObject
        let view: UIView
        let invalidate: () -> Void
        if style == .pageCurl {
            let parent = curlViewport(plan: plan, onBoundary: { boundaries.append($0) })
            let owner = parent.makeCoordinator()
            let container = MangaPagedPageCurlContainerViewController(pageViewController: UIPageViewController(
                transitionStyle: .pageCurl, navigationOrientation: .horizontal))
            container.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            container.view.layoutIfNeeded()
            let gestures = MangaPagedPageCurlNavigationAdapter(coordinator: owner, input: input)
            gestures.configureContainerGestures(in: container)
            gestures.configureGestures(in: container.pageViewController)
            adapter = gestures
            coordinator = owner
            view = container.pageViewController.view
            invalidate = {
                // Keep the installed container alive for the recognizer's complete lifecycle.
                _ = container
                if invalidation == "generation" { owner.interactionRuntime.reset() }
                if invalidation == "chrome" {
                    owner.parent = curlViewport(plan: plan, chrome: true, onBoundary: { boundaries.append($0) })
                }
                if invalidation == "detach" { gestures.detach() }
            }
        } else {
            let parent = MangaPagedReaderViewport(plan: plan, viewportPlacement: nil, settings: settings,
                imageLoader: loader(), isChromeVisible: false, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: { _ in },
                canBoundaryPageTurn: { _ in true }, onBoundaryPageTurn: { boundaries.append($0) },
                onPageLongPress: { _ in }, onTap: {})
            let owner = parent.makeCoordinator()
            let collection = MangaPagedReaderCollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 800),
                collectionViewLayout: UICollectionViewFlowLayout())
            let gestures = MangaPagedScrollNavigationAdapter(coordinator: owner, input: input)
            gestures.install(in: collection)
            adapter = gestures
            coordinator = owner
            view = collection
            invalidate = {
                if invalidation == "generation" { owner.interactionRuntime.reset() }
                if invalidation == "chrome" {
                    owner.parent = MangaPagedReaderViewport(plan: plan, viewportPlacement: nil, settings: settings,
                        imageLoader: parent.imageLoader, isChromeVisible: true, zoomEnabled: true, likedPageIDs: [],
                        controlPageTurnBridge: parent.controlPageTurnBridge, onCurrentPageChange: { _ in },
                        canBoundaryPageTurn: { _ in true }, onBoundaryPageTurn: { boundaries.append($0) },
                        onPageLongPress: { _ in }, onTap: {})
                }
                if invalidation == "detach" { input.detach() }
            }
        }
        withExtendedLifetime((adapter, coordinator, view, invalidate)) {
            pan.translationValue = CGPoint(x: -2, y: 0)
            #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
            pan.send(.began)
            invalidate()
            if invalidation == "cancel" { pan.send(.cancelled) }
            pan.translationValue = CGPoint(x: -100, y: 0)
            pan.velocityValue = CGPoint(x: 1, y: 2)
            pan.send(.ended)
            pan.send(.ended)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(boundaries == (invalidation == "none" ? [1] : []))
            input.detach()
        }
    }

    @Test func staleCurlCompletionCleansUpItsDisplayLink() throws {
        let owner = curlViewport(plan: MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)).makeCoordinator()
        let controller = DeferredPageController()
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: true)
        #expect(owner.pageCurlBackColorDisplayLink != nil)
        owner.interactionRuntime.reset()
        controller.complete(0)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
        #expect(!owner.isPageTurnInProgress)
    }

    @Test func curlReplacementAndDismantleReleaseResourcesWithoutStoppingNewAnimation() throws {
        let owner = curlViewport(plan: MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)).makeCoordinator()
        let controller = DeferredPageController()
        let container = MangaPagedPageCurlContainerViewController(pageViewController: controller)
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: true)
        owner.interactionRuntime.reset()
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: false)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: true)
        let currentLink = try #require(owner.pageCurlBackColorDisplayLink)
        controller.complete(0)
        controller.complete(1)
        #expect(owner.pageCurlBackColorDisplayLink === currentLink)
        #expect(owner.isPageTurnInProgress)
        MangaPagedPageCurlReaderViewport.dismantleUIViewController(container, coordinator: owner)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
        #expect(!owner.isPageTurnInProgress)
        controller.complete(2)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
    }

    @Test func synchronousCurlCompletionCannotLeaveARefreshRunning() throws {
        let owner = curlViewport(plan: MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)).makeCoordinator()
        let controller = DeferredPageController()
        controller.completesSynchronously = true
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: true)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
        #expect(!owner.isPageTurnInProgress)
    }

    @Test(arguments: [false, true], [MangaPageTurnDirection.leftToRight, .rightToLeft])
    func rapidCurlNavigationCompletesBeforeAcceptingAnotherTurn(twoPages: Bool, direction: MangaPageTurnDirection) throws {
        let plan = MangaPagedReadingPlan(pages: try curlPages(), currentPageIndex: 0,
            pageTurnDirection: direction, usesTwoPageSpread: twoPages)
        var reportedPages: [Int] = []
        var boundaries: [Int] = []
        let owner = curlViewport(plan: plan, onPageChange: { reportedPages.append($0) },
            onBoundary: { boundaries.append($0) }).makeCoordinator()
        let controller = DeferredPageController()
        let container = MangaPagedPageCurlContainerViewController(pageViewController: controller)
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: false)

        owner.gestures.routeControl(.forward, in: container)
        for _ in 0..<10 {
            owner.gestures.routeControl(.forward, in: container)
            owner.gestures.routeControl(.backward, in: container)
            owner.animateAdjacentSelection(delta: 1, in: controller)
        }
        #expect(controller.selectionCount == 2)
        #expect(boundaries.isEmpty)
        #expect(reportedPages.isEmpty)
        controller.complete(1)
        #expect(reportedPages == [twoPages ? 3 : 1])

        // The parent still describes page zero until SwiftUI delivers the next update.
        owner.gestures.routeControl(.forward, in: container)
        #expect(controller.selectionCount == 3)
        controller.complete(2)
        #expect(reportedPages == (twoPages ? [3, 5] : [1, 2]))
        owner.gestures.routeControl(.backward, in: container)
        #expect(controller.selectionCount == 4)
        #expect(boundaries.isEmpty)
        controller.complete(3)
        #expect(reportedPages == (twoPages ? [3, 5, 3] : [1, 2, 1]))
    }

    @Test func curlBoundaryUsesCompletedSelectionBeforeParentUpdate() throws {
        let plan = MangaPagedReadingPlan(pages: Array(try curlPages().prefix(2)), currentPageIndex: 0)
        var boundaries: [Int] = []
        let owner = curlViewport(plan: plan, onBoundary: { boundaries.append($0) }).makeCoordinator()
        let controller = DeferredPageController()
        let container = MangaPagedPageCurlContainerViewController(pageViewController: controller)
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: false)
        owner.gestures.routeControl(.forward, in: container)
        controller.complete(1)
        owner.gestures.routeControl(.forward, in: container)
        #expect(boundaries == [1])
        #expect(controller.selectionCount == 2)
    }

    @Test(arguments: [false, true])
    func unsuccessfulCurlCompletionAllowsRetry(invalidateGeneration: Bool) throws {
        let plan = MangaPagedReadingPlan(pages: try curlPages(), currentPageIndex: 0)
        var reportedPages: [Int] = []
        let owner = curlViewport(plan: plan, onPageChange: { reportedPages.append($0) }).makeCoordinator()
        let controller = DeferredPageController()
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: false)
        owner.animateAdjacentSelection(delta: 1, in: controller)
        if invalidateGeneration { owner.interactionRuntime.reset() }
        controller.complete(1, finished: invalidateGeneration)
        #expect(!owner.isPageTurnInProgress)
        #expect(reportedPages.isEmpty)
        owner.animateAdjacentSelection(delta: 1, in: controller)
        #expect(controller.selectionCount == 3)
        controller.complete(2)
        #expect(reportedPages == [1])
    }

    @Test(arguments: [false, true])
    func interactiveCurlCannotBeReplacedByTap(completed: Bool) throws {
        let plan = MangaPagedReadingPlan(pages: try curlPages(), currentPageIndex: 0)
        var reportedPages: [Int] = []
        let owner = curlViewport(plan: plan, onPageChange: { reportedPages.append($0) }).makeCoordinator()
        let controller = DeferredPageController()
        defer { owner.invalidatePageCurlTransitions() }
        owner.setCurrentSelection(in: controller, selectionIndex: 0, animated: false)
        let previous = try #require(controller.viewControllers)
        let next = try #require(owner.pageViewController(controller, viewControllerAfter: previous[0]))
        owner.pageViewController(controller, willTransitionTo: [next])
        owner.animateAdjacentSelection(delta: 1, in: controller)
        #expect(controller.selectionCount == 1)
        #expect(owner.isPageTurnInProgress)
        if completed { controller.setViewControllers([next], direction: .forward, animated: false) }
        owner.pageViewController(controller, didFinishAnimating: true,
            previousViewControllers: previous, transitionCompleted: completed)
        #expect(!owner.isPageTurnInProgress)
        #expect(reportedPages == (completed ? [1] : []))
        owner.animateAdjacentSelection(delta: 1, in: controller)
        #expect(owner.isPageTurnInProgress)
        controller.complete(controller.selectionCount - 1)
        #expect(reportedPages == (completed ? [1, 2] : [1]))
    }

    private func curlPages() throws -> [MangaReaderPageProjection] {
        let page = try makePipelinePage()
        return (0..<6).map { index in
            var page = page
            page.globalIndex = index
            page.localIndex = index
            page.chapterPageCount = 6
            return page
        }
    }

    private func curlViewport(plan: MangaPagedReadingPlan, chrome: Bool = false,
        onPageChange: @escaping (Int) -> Void = { _ in },
        onBoundary: @escaping (Int) -> Void = { _ in }) -> MangaPagedPageCurlReaderViewport {
        MangaPagedPageCurlReaderViewport(plan: plan, viewportPlacement: nil,
            settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .pageCurl, pageTurnDirection: plan.pageTurnDirection),
            imageLoader: loader(), isChromeVisible: chrome, zoomEnabled: true, likedPageIDs: [],
            controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: onPageChange,
            canBoundaryPageTurn: { _ in true }, onBoundaryPageTurn: onBoundary, onPageLongPress: { _ in }, onTap: {})
    }

    private func loader() -> MangaReaderPageImageLoader {
        MangaReaderPageImageLoader(imageSource: { _ in
            YamiboImageSource(url: URL(fileURLWithPath: "/nonexistent/manga-interaction-test.png"))
        })
    }

    private final class PlacementCollection: UICollectionView {
        var animatedPlacements: [Bool] = []
        override func scrollToItem(at indexPath: IndexPath, at scrollPosition: UICollectionView.ScrollPosition, animated: Bool) {
            animatedPlacements.append(animated)
        }
    }

    private final class EventPan: UIPanGestureRecognizer {
        var translationValue: CGPoint = .zero
        var velocityValue: CGPoint = .zero
        private var eventState: UIGestureRecognizer.State = .possible
        private weak var eventTarget: NSObject?
        private var eventAction: Selector?

        override var state: UIGestureRecognizer.State {
            get { eventState }
            set { eventState = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { translationValue }
        override func velocity(in view: UIView?) -> CGPoint { velocityValue }
        override func addTarget(_ target: Any, action: Selector) {
            super.addTarget(target, action: action)
            eventTarget = target as? NSObject
            eventAction = action
        }
        func send(_ state: UIGestureRecognizer.State) {
            eventState = state
            if let eventAction { _ = eventTarget?.perform(eventAction, with: self) }
        }
    }

    private final class DeferredPageController: UIPageViewController {
        private var installedControllers: [UIViewController]?
        private var completions: [((Bool) -> Void)?] = []
        var selectionCount: Int { completions.count }
        var completesSynchronously = false
        override var viewControllers: [UIViewController]? { installedControllers }
        override func setViewControllers(_ viewControllers: [UIViewController]?, direction: UIPageViewController.NavigationDirection,
            animated: Bool, completion: ((Bool) -> Void)? = nil) {
            installedControllers = viewControllers
            completions.append(completion)
            if completesSynchronously { completion?(true) }
        }
        func complete(_ index: Int, finished: Bool = true) { completions[index]?(finished) }
    }
}
#endif
