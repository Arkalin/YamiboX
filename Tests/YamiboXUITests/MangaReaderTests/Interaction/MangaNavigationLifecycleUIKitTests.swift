#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged navigation completion integration")
struct MangaNavigationLifecycleUIKitTests {
    @Test(arguments: [false, true], ["none", "generation", "chrome", "cancel", "detach"])
    func installedPanKeepsAdmissionUntilCompletion(curl: Bool, invalidation: String) throws {
        var boundaries: [Int] = []
        let plan = MangaPagedReadingPlan(pages: [try makePipelinePage()], currentPageIndex: 0)
        let pan = EventPan()
        let input = MangaNavigationInput(navigationPan: pan)
        let settings = MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .quickFade, pageTurnDirection: .leftToRight)
        let adapter: AnyObject
        let coordinator: AnyObject
        let view: UIView
        let invalidate: () -> Void
        if curl {
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
        MangaPagedPageCurlReaderViewport.dismantleUIViewController(container, coordinator: owner)
        #expect(owner.pageCurlBackColorDisplayLink == nil)
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
    }

    private func curlViewport(plan: MangaPagedReadingPlan, chrome: Bool = false,
        onBoundary: @escaping (Int) -> Void = { _ in }) -> MangaPagedPageCurlReaderViewport {
        MangaPagedPageCurlReaderViewport(plan: plan, viewportPlacement: nil,
            settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .pageCurl, pageTurnDirection: .leftToRight),
            imageLoader: loader(), isChromeVisible: chrome, zoomEnabled: true, likedPageIDs: [],
            controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: { _ in },
            canBoundaryPageTurn: { _ in true }, onBoundaryPageTurn: onBoundary, onPageLongPress: { _ in }, onTap: {})
    }

    private func loader() -> MangaReaderPageImageLoader {
        MangaReaderPageImageLoader(imageSource: { _ in
            YamiboImageSource(url: URL(fileURLWithPath: "/nonexistent/manga-interaction-test.png"))
        })
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
        var completesSynchronously = false
        override var viewControllers: [UIViewController]? { installedControllers }
        override func setViewControllers(_ viewControllers: [UIViewController]?, direction: UIPageViewController.NavigationDirection,
            animated: Bool, completion: ((Bool) -> Void)? = nil) {
            installedControllers = viewControllers
            completions.append(completion)
            if completesSynchronously { completion?(true) }
        }
        func complete(_ index: Int) { completions[index]?(true) }
    }
}
#endif
