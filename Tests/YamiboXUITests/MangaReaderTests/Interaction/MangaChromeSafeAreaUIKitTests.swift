#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged chrome safe-area geometry", .serialized)
struct MangaChromeSafeAreaUIKitTests {
    @Test(arguments: [ReaderPagedTurnStyle.none, .slide, .quickFade], [false, true])
    func collectionHostedPagesKeepWindowFramesWhenChromeChangesSafeArea(
        turnStyle: ReaderPagedTurnStyle,
        usesTwoPageSpread: Bool
    ) async throws {
        let first = try makePipelinePage()
        var second = first
        second.globalIndex = 1
        second.localIndex = 1
        let pages = usesTwoPageSpread ? [first, second] : [first]
        let loader = try await imageLoader(page: first)
        let plan = MangaPagedReadingPlan(pages: pages, currentPageIndex: 0,
            pageTurnDirection: .leftToRight, usesTwoPageSpread: usesTwoPageSpread)
        let bridge = MangaPagedControlPageTurnBridge()
        func viewport(chrome: Bool) -> MangaPagedReaderViewport {
            MangaPagedReaderViewport(plan: plan, viewportPlacement: nil,
                settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: turnStyle,
                    pageTurnDirection: .leftToRight, pageScaleMode: .fitHeight),
                imageLoader: loader, isChromeVisible: chrome, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: bridge, onCurrentPageChange: { _ in },
                canBoundaryPageTurn: { _ in false }, onBoundaryPageTurn: { _ in },
                onPageLongPress: { _ in }, onTap: {})
        }
        let owner = viewport(chrome: false).makeCoordinator()
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let collection = MangaPagedReaderCollectionView(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700), collectionViewLayout: layout)
        collection.contentInsetAdjustmentBehavior = .never
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.dataSource = owner
        collection.delegate = owner
        collection.register(ReaderPagedPageTurnCell.self,
            forCellWithReuseIdentifier: MangaPagedScrollCoordinator.reuseIdentifier)
        let controller = UIViewController()
        controller.view.addSubview(collection)
        let window = UIWindow(frame: collection.frame)
        window.rootViewController = controller
        window.isHidden = false
        collection.frame = controller.view.bounds
        defer {
            MangaPagedReaderViewport.dismantleUIView(collection, coordinator: owner)
            window.isHidden = true
            window.rootViewController = nil
        }

        owner.updateContentIfNeeded(in: collection)
        try await waitUntil {
            loadedImages(in: collection).count == pages.count
                && pages.allSatisfy { owner.pageSurfaceInteractions[$0.id]?.runtime.imageLoaded == true }
        }
        await settleLayout(controller)
        let originalInsets = controller.view.safeAreaInsets
        let baseline = snapshot(collection, in: window)
        try #require(baseline.imageFrames.count == pages.count)
        try #require(baseline.surfaceFrames.count == pages.count)
        try #require(baseline.imageFrames.allSatisfy { $0.width > 0 && $0.height > 0 })

        // Native scroll coordinates can remain unchanged while the nested
        // SwiftUI host shifts every bitmap, so compare actual window frames.
        for topInset in [CGFloat(64), 0, 88, 0] {
            let chrome = topInset > 0
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            owner.parent = viewport(chrome: chrome)
            owner.updateContentIfNeeded(in: collection)
            try await waitUntil {
                loadedImages(in: collection).count == pages.count
                    && pages.allSatisfy { owner.pageSurfaceInteractions[$0.id]?.runtime.configuration.chromeVisible == chrome }
            }
            await settleLayout(controller)
            #expect(abs(controller.view.safeAreaInsets.top - originalInsets.top - topInset) < 0.5)
            let current = snapshot(collection, in: window)
            expectSameFrames(current.surfaceFrames, baseline.surfaceFrames)
            expectSameFrames(current.imageFrames, baseline.imageFrames)
        }
    }

    private func snapshot(_ collection: UICollectionView, in window: UIWindow) -> PageFrames {
        let images = loadedImages(in: collection)
        let surfaces = descendants(in: collection).compactMap { $0 as? MangaNativeSurfaceView }.filter { surface in
            surface.zoomContentView.subviews.contains { ($0 as? UIImageView)?.image != nil }
        }
        return PageFrames(
            imageFrames: images.map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX },
            surfaceFrames: surfaces.map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }
        )
    }

    private func loadedImages(in collection: UICollectionView) -> [UIImageView] {
        collection.visibleCells.flatMap { descendants(in: $0) }
            .compactMap { $0 as? UIImageView }.filter { $0.image != nil }
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func expectSameFrames(_ current: [CGRect], _ expected: [CGRect]) {
        #expect(current.count == expected.count)
        for (actual, baseline) in zip(current, expected) {
            #expect(abs(actual.minX - baseline.minX) < 0.5)
            #expect(abs(actual.minY - baseline.minY) < 0.5)
            #expect(abs(actual.width - baseline.width) < 0.5)
            #expect(abs(actual.height - baseline.height) < 0.5)
        }
    }

    private func imageLoader(page: MangaReaderPageProjection) async throws -> MangaReaderPageImageLoader {
        let provider = ReaderImageCacheDataProvider(data: try ReaderImageCacheFixture.png(width: 600, height: 800))
        let pipeline = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: provider))
        let source = ReaderImageCacheFixture.source(0)
        let loader = MangaReaderPageImageLoader(imageSource: { _ in source }, uiImagePipeline: pipeline)
        _ = try await loader.image(for: page)
        return loader
    }

    private func settleLayout(_ controller: UIViewController) async {
        for _ in 0..<8 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private struct PageFrames {
        let imageFrames: [CGRect]
        let surfaceFrames: [CGRect]
    }
}
#endif
