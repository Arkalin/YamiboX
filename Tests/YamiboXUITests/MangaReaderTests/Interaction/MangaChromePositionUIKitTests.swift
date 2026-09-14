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
            MangaPagedReaderViewport(attachedInformation: information(pages: [page], index: 0, chrome: chrome),
                plan: MangaPagedReadingPlan(pages: [page], currentPageIndex: 0,
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
        #expect(runtime.perform(.edge(edge), animated: false) == .reveal(edge))
        try await waitUntil { !runtime.hiddenEdges.contains(edge) }
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
            #expect(owner.informationState.configuration.presentation.isChromeVisible == chrome)
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
            MangaPagedPageCurlReaderViewport(attachedInformation: information(pages: pages, index: index, chrome: chrome),
                plan: MangaPagedReadingPlan(pages: pages, currentPageIndex: index,
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
                #expect(runtime.perform(.edge(edge), animated: false) == .reveal(edge))
                try await waitUntil { !runtime.hiddenEdges.contains(edge) }
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
                #expect(controller.rootView.informationState === owner.informationState)
                #expect(owner.informationState.configuration.presentation.isChromeVisible == chrome)
            }

            let back = try #require(owner.pageViewController(pageController,
                viewControllerAfter: controller) as? MangaPagedPageCurlHostingController)
            #expect(back.leaf.isBack)
            #expect(back.leaf.pageID == controller.leaf.pageID)
            #expect(back.rootView.pageSurface == nil)
            let generation = runtime.generation
            let backWindow = show(back)
            defer { backWindow.isHidden = true; backWindow.rootViewController = nil }
            owner.pageViewController(pageController, willTransitionTo: [back])
            let copy = try #require(back.rootView.backContent)
            #expect(copy.image != nil)
            #expect(copy.geometry == geometry)
            #expect(copy.transform == transform)
            #expect(copy.imageFrame(in: geometry.viewport) == geometry.nativeImageFrame(transform))
            #expect(runtime.imageLoaded)
            #expect(runtime.generation == generation)
            #expect(runtime.transform == transform)
            owner.pageViewController(pageController, didFinishAnimating: true,
                previousViewControllers: [controller], transitionCompleted: false)
            #expect(runtime.transform == transform)
        }

        let nextIndex = 1 - index
        owner.setCurrentSelection(in: pageController, selectionIndex: nextIndex, animated: false)
        let nextController = try #require(pageController.viewControllers?.first as? MangaPagedPageCurlHostingController)
        let nextAlignment = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: direction, pageScaleMode: .fitHeight, currentPageIndex: index, targetPageIndex: nextIndex)
        #expect(nextController.rootView.pageSurface?.initialHorizontalAlignment == nextAlignment)
    }

    @Test(arguments: [MangaPageEdgeFillStyle.black, .white, .system], [ColorScheme.light, .dark])
    func curlBackRendersMirroredInkOnOpaquePaper(fill: MangaPageEdgeFillStyle, scheme: ColorScheme) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        let page = try makePipelinePage()
        let loader = MangaReaderPageImageLoader(imageSource: { _ in
            YamiboImageSource(url: page.imageURL)
        }, uiImagePipeline: YamiboUIImagePipeline(core: YamiboImagePipeline()))
        let content = MangaPagedPageCurlBackContent(image: image,
            geometry: .image(size: image.size, viewport: .zero, fit: .fitWidth, alignment: .left),
            transform: MangaSurfaceTransform())
        for loaded in [true, false] {
            let view = MangaPagedPageCurlLeafView(informationState: ReaderAttachedInformationState(),
                informationIndex: 0, informationSlot: 0, pageSurface: nil, imageLoader: loader,
                pageScaleMode: .fitWidth, pageEdgeFillStyle: fill, zoomEnabled: false,
                isPageZoomEnabled: false, likedPageIDs: [], isBack: true, backContent: loaded ? content : nil)
                .environment(\.colorScheme, scheme)
                .frame(width: 100, height: 100)
            let renderer = ImageRenderer(content: view)
            let rendered = try #require(renderer.cgImage)
            let left = try pixel(rendered, x: 25, y: 50)
            let right = try pixel(rendered, x: 75, y: 50)
            let base: Double = fill.uiColor(for: scheme) == .white ? 255 : 0
            let faint = base * 0.82
            let ink = faint + 255 * 0.18
            for (actual, expected) in zip(left, loaded ? [faint, faint, ink, 255] : [base, base, base, 255]) {
                #expect(abs(Double(actual) - expected) <= 2)
            }
            for (actual, expected) in zip(right, loaded ? [ink, faint, faint, 255] : [base, base, base, 255]) {
                #expect(abs(Double(actual) - expected) <= 2)
            }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (y * image.width + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    @Test func spreadZoomMovesInformationToUnscaledContainerWithoutResettingZoom() async throws {
        let first = try makePipelinePage()
        var second = first
        second.globalIndex = 1
        second.localIndex = 1
        let pages = [first, second]
        let loader = try await imageLoader(page: first)
        let plan = MangaPagedReadingPlan(pages: pages, currentPageIndex: 0, usesTwoPageSpread: true)
        let settings = MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .pageCurl)
        let parent = MangaPagedPageCurlReaderViewport(attachedInformation: information(pages: pages, index: 0, chrome: false),
            plan: plan, viewportPlacement: nil, settings: settings, imageLoader: loader, isChromeVisible: false,
            zoomEnabled: true, likedPageIDs: [], controlPageTurnBridge: MangaPagedControlPageTurnBridge(),
            onCurrentPageChange: { _ in }, canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in },
            onPageLongPress: { _ in }, onTap: {})
        let owner = parent.makeCoordinator()
        let pager = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.mid.rawValue])
        let container = MangaPagedPageCurlContainerViewController(pageViewController: pager, informationState: owner.informationState)
        let window = show(container)
        defer {
            MangaPagedPageCurlReaderViewport.dismantleUIViewController(container, coordinator: owner)
            window.isHidden = true
            window.rootViewController = nil
        }
        let identity = MangaPagedReaderContentIdentity(spreadIDs: plan.spreads.map(\.id), pageScaleMode: .fitWidth,
            pagedTurnStyle: .pageCurl, pageTurnDirection: settings.pageTurnDirection,
            pageEdgeFillStyle: settings.pageEdgeFillStyle, colorScheme: .light)
        owner.update(container, contentIdentity: identity)
        owner.zoom.updatePageCurlSpreadZoomAvailability(in: container)
        try await waitUntil { owner.pageSurfaceInteractions.values.allSatisfy { $0.runtime.imageLoaded } }
        container.zoomView.zoom(factor: 2, centeredAt: CGPoint(x: 200, y: 400), animated: false)
        try await waitUntil { owner.informationState.usesStationaryZoomInformation }
        let snapshot = container.zoomView.snapshot
        for chrome in [true, false] {
            owner.parent = MangaPagedPageCurlReaderViewport(attachedInformation: information(pages: pages, index: 0, chrome: chrome),
                plan: plan, viewportPlacement: nil, settings: settings, imageLoader: loader, isChromeVisible: chrome,
                zoomEnabled: true, likedPageIDs: [], controlPageTurnBridge: parent.controlPageTurnBridge,
                onCurrentPageChange: { _ in }, canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in },
                onPageLongPress: { _ in }, onTap: {})
            owner.update(container, contentIdentity: identity)
            #expect(container.zoomView.snapshot.factor == snapshot.factor)
            #expect(container.zoomView.snapshot.visibleRect == snapshot.visibleRect)
            #expect(owner.informationState.usesStationaryZoomInformation)
        }
        container.zoomView.resetZoom(animated: false)
        try await waitUntil { !owner.informationState.usesStationaryZoomInformation }
    }

    private func information(pages: [MangaReaderPageProjection], index: Int, chrome: Bool) -> ReaderAttachedInformationConfiguration {
        let presentation = ReaderPageInformationPresentation(isPaged: true, isImmersive: false, isChromeVisible: chrome)
        let plan = MangaPagedReadingPlan(pages: pages, currentPageIndex: index)
        return ReaderAttachedInformationConfiguration(
            pages: MangaAttachedPageInformation.pages(plan: plan, workTitle: "Book", information: presentation, chapterTitle: { $0.chapterTitle }),
            presentation: presentation, selectedIndex: index, topInset: 32, bottomInset: 20)
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
