#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged chrome position integration", .serialized)
struct MangaChromePositionUIKitTests {
    @Test(arguments: [MangaPageTurnDirection.leftToRight, .rightToLeft])
    func collectionCellRefreshPreservesRevealedEdge(direction: MangaPageTurnDirection) async throws {
        let page = try makePipelinePage()
        let loader = try await imageLoader(page: page)
        func viewport(chrome: Bool) -> MangaPagedReaderViewport {
            MangaPagedReaderViewport(plan: MangaPagedReadingPlan(pages: [page], currentPageIndex: 0,
                pageTurnDirection: direction), viewportPlacement: nil,
                settings: MangaReaderSettings(readingMode: .paged, pageTurnDirection: direction, pageScaleMode: .fitHeight),
                imageLoader: loader, isChromeVisible: chrome, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: { _ in },
                canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in }, onPageLongPress: { _ in }, onTap: {})
        }
        let owner = viewport(chrome: false).makeCoordinator()
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), collectionViewLayout: layout)
        collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = owner
        collection.delegate = owner
        collection.register(ReaderPagedPageTurnCell.self, forCellWithReuseIdentifier: MangaPagedScrollCoordinator.reuseIdentifier)
        let controller = UIViewController()
        controller.view.addSubview(collection)
        let window = show(controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        owner.updateContentIfNeeded(in: collection)
        let runtime = try #require(owner.pageSurfaceInteractions[page.id]?.runtime)
        try await waitUntil { runtime.imageLoaded }
        let edge: MangaPagedImageSurfaceHorizontalEdge = direction == .leftToRight ? .right : .left
        #expect(runtime.perform(.edge(edge)) == .reveal(edge))
        let revealed = runtime.transform
        let geometry = runtime.geometry
        #expect(revealed.offset.width != 0)

        for chrome in [true, false, true, false] {
            #expect(runtime.perform(.centerTap) == .toggleChrome)
            owner.parent = viewport(chrome: chrome)
            owner.updateContentIfNeeded(in: collection)
            try await waitUntil { runtime.configuration.chromeVisible == chrome }
            #expect(runtime.transform == revealed)
            #expect(runtime.geometry == geometry)
            #expect(!runtime.hiddenEdges.contains(edge))
        }
    }

    @Test(arguments: [MangaPageTurnDirection.leftToRight, .rightToLeft], [false, true])
    func curlChromeRefreshPreservesPagePosition(direction: MangaPageTurnDirection, backwardEntry: Bool) async throws {
        let first = try makePipelinePage()
        var second = first
        second.globalIndex = 1
        second.localIndex = 1
        let pages = [first, second]
        let loader = try await imageLoader(page: first)
        let settings = MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .pageCurl,
            pageTurnDirection: direction, pageScaleMode: .fitHeight)
        func viewport(index: Int, chrome: Bool) -> MangaPagedPageCurlReaderViewport {
            MangaPagedPageCurlReaderViewport(plan: MangaPagedReadingPlan(pages: pages, currentPageIndex: index,
                pageTurnDirection: direction), viewportPlacement: nil, settings: settings,
                imageLoader: loader, isChromeVisible: chrome, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: MangaPagedControlPageTurnBridge(), onCurrentPageChange: { _ in },
                canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in },
                onPageLongPress: { _ in }, onTap: {})
        }
        let owner = viewport(index: 1, chrome: false).makeCoordinator()
        let pageController = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let container = MangaPagedPageCurlContainerViewController(pageViewController: pageController)
        let window = show(container)
        defer {
            MangaPagedPageCurlReaderViewport.dismantleUIViewController(container, coordinator: owner)
            window.isHidden = true
            window.rootViewController = nil
        }
        let identity = MangaPagedReaderContentIdentity(spreadIDs: owner.parent.plan.spreads.map(\.id),
            pageScaleMode: .fitHeight, pagedTurnStyle: .pageCurl, pageTurnDirection: direction,
            pageEdgeFillStyle: settings.pageEdgeFillStyle, colorScheme: .light)
        owner.update(container, contentIdentity: identity)
        let index = backwardEntry ? 0 : 1
        owner.setCurrentSelection(in: pageController, selectionIndex: index, animated: false)
        container.view.layoutIfNeeded()
        let controller = try #require(pageController.viewControllers?.first as? MangaPagedPageCurlHostingController)
        let surface = try #require(controller.rootView.pageSurface)
        let alignment: MangaPagedImageSurfaceInitialHorizontalAlignment = backwardEntry
            ? (direction == .leftToRight ? .right : .left)
            : MangaPagedImageSurfaceInitialHorizontalAlignment(pageTurnDirection: direction)
        #expect(surface.initialHorizontalAlignment == alignment)
        let runtime = surface.surfaceInteraction.runtime
        try await waitUntil { runtime.imageLoaded }
        let geometry = runtime.geometry

        for revealOppositeEdge in [false, true] {
            if revealOppositeEdge {
                let edge: MangaPagedImageSurfaceHorizontalEdge = alignment == .left ? .right : .left
                #expect(runtime.perform(.edge(edge)) == .reveal(edge))
                #expect(runtime.transform.offset.width != 0)
            }
            let transform = runtime.transform
            // Selection has caught up, but this is still the same mounted page appearance.
            for chrome in [true, false, true, false] {
                #expect(runtime.perform(.centerTap) == .toggleChrome)
                owner.parent = viewport(index: index, chrome: chrome)
                owner.update(container, contentIdentity: identity)
                try await waitUntil { runtime.configuration.chromeVisible == chrome }
                #expect(controller.rootView.pageSurface?.initialHorizontalAlignment == alignment)
                #expect(runtime.geometry == geometry)
                #expect(runtime.transform == transform)
            }
        }

        let nextIndex = 1 - index
        owner.setCurrentSelection(in: pageController, selectionIndex: nextIndex, animated: false)
        let nextController = try #require(pageController.viewControllers?.first as? MangaPagedPageCurlHostingController)
        let nextAlignment = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: direction, pageScaleMode: .fitHeight, currentPageIndex: index, targetPageIndex: nextIndex)
        #expect(nextController.rootView.pageSurface?.initialHorizontalAlignment == nextAlignment)
    }

    private func imageLoader(page: MangaReaderPageProjection) async throws -> MangaReaderPageImageLoader {
        let provider = ReaderImageCacheDataProvider(data: try ReaderImageCacheFixture.png(width: 1200, height: 800))
        let pipeline = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: provider))
        let source = ReaderImageCacheFixture.source(0)
        let loader = MangaReaderPageImageLoader(imageSource: { _ in source }, uiImagePipeline: pipeline)
        _ = try await loader.image(for: page)
        return loader
    }

    private func show(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
#endif
