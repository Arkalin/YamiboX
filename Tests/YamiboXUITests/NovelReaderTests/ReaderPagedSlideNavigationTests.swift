#if os(iOS)
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Shared slide paging", .serialized)
struct ReaderPagedSlideNavigationTests {
    @Test(arguments: [false, true])
    func rapidTapsSettleOnAWholePage(reversed: Bool) throws {
        let fixture = SlideFixture(reversed: reversed)
        defer { fixture.close() }
        let start = fixture.collection.contentOffset.x
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        for tick in 1...12 {
            animation.advance(elapsedTime: Double(tick) * 0.02)
            #expect(fixture.turn(.next))
            #expect(fixture.driver.slideAnimation === animation)
        }
        animation.advance(elapsedTime: 0.3)
        let offset = fixture.collection.contentOffset.x
        #expect(abs(offset - start) > 1)
        #expect(abs(offset / 400 - (offset / 400).rounded()) < 0.001)
        #expect(fixture.inputs.selectionIndex == 1)
        #expect(fixture.turn(.next))
        fixture.driver.slideAnimation?.advance(elapsedTime: 0.3)
        #expect(fixture.inputs.selectionIndex == 2)
        #expect(fixture.turn(.previous))
        fixture.driver.slideAnimation?.advance(elapsedTime: 0.3)
        #expect(fixture.inputs.selectionIndex == 1)
    }

    @Test func unchangedViewUpdateDoesNotRewindAnActiveTurn() throws {
        let fixture = SlideFixture()
        defer { fixture.close() }
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        animation.advance(elapsedTime: 0.08)
        let beforeUpdate = fixture.collection.contentOffset.x
        #expect(beforeUpdate > 0)
        fixture.driver.updateContentAndRequestSelectionScroll(
            in: fixture.collection, didChangeContentIdentity: false, inputs: fixture.inputs)
        #expect(fixture.collection.contentOffset.x >= beforeUpdate)
        animation.advance(elapsedTime: 0.3)
        #expect(abs(fixture.collection.contentOffset.x - 400) < 0.5)
        #expect(fixture.inputs.selectionIndex == 1)
    }

    @Test func repeatedTapsDoNotRestartOrInterruptTheActiveAnimation() throws {
        let fixture = SlideFixture()
        defer { fixture.close() }
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        var lastOffset: CGFloat = 0
        for tick in 1...5 {
            animation.advance(elapsedTime: Double(tick) * 0.03)
            #expect(fixture.collection.contentOffset.x > lastOffset)
            lastOffset = fixture.collection.contentOffset.x
            // Simulate UIScrollView's native animation being stopped by a touch.
            fixture.collection.setContentOffset(fixture.collection.contentOffset, animated: false)
            #expect(fixture.turn(.next))
            #expect(fixture.turn(.previous))
            #expect(!fixture.turn(.toggleChrome))
        }
        animation.advance(elapsedTime: 0.3)
        #expect(abs(fixture.collection.contentOffset.x - 400) < 0.5)
        #expect(fixture.selectionChanges == [1])
        #expect(!fixture.driver.isPerformingSlideTransition)
    }

    @Test func draggingTakesOverAtTheVisibleOffset() throws {
        let fixture = SlideFixture()
        defer { fixture.close() }
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        animation.advance(elapsedTime: 0.08)
        let offset = fixture.collection.contentOffset
        fixture.driver.scrollViewWillBeginDragging(fixture.collection, inputs: fixture.inputs)
        #expect(!fixture.driver.isPerformingSlideTransition)
        animation.advance(elapsedTime: 0.3)
        #expect(fixture.collection.contentOffset == offset)
        #expect(fixture.selectionChanges.isEmpty)
        fixture.collection.setContentOffset(.zero, animated: false)
        fixture.driver.scrollViewDidEndDragging(fixture.collection, willDecelerate: false, inputs: fixture.inputs)
        #expect(fixture.turn(.next))
        fixture.driver.slideAnimation?.advance(elapsedTime: 0.3)
        #expect(fixture.selectionChanges == [1])
    }

    @Test func explicitPlacementCancelsTheOldCompletion() throws {
        let fixture = SlideFixture()
        defer { fixture.close() }
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        animation.advance(elapsedTime: 0.06)
        var placementInputs = fixture.inputs
        placementInputs.selectionIndex = 3
        #expect(fixture.driver.requestSelectionScroll(in: fixture.collection, animated: false, inputs: placementInputs))
        #expect(!fixture.driver.isPerformingSlideTransition)
        animation.advance(elapsedTime: 0.3)
        #expect(abs(fixture.collection.contentOffset.x - 1200) < 0.5)
        #expect(!fixture.selectionChanges.contains(1))
    }

    @Test func detachedViewportReleasesItsAnimationWithoutPublishing() throws {
        let fixture = SlideFixture()
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        fixture.close()
        animation.advance(elapsedTime: 0.1)
        #expect(!fixture.driver.isPerformingSlideTransition)
        #expect(fixture.selectionChanges.isEmpty)
    }

    @Test func boundsChangeRealignsWithoutPublishingTheOldTarget() throws {
        let fixture = SlideFixture()
        defer { fixture.close() }
        #expect(fixture.turn(.next))
        let animation = try #require(fixture.driver.slideAnimation)
        animation.advance(elapsedTime: 0.08)
        fixture.collection.frame.size.width = 300
        fixture.collection.collectionViewLayout.invalidateLayout()
        animation.advance(elapsedTime: 0.15)
        #expect(!fixture.driver.isPerformingSlideTransition)
        #expect(fixture.collection.contentOffset.x == 0)
        #expect(fixture.selectionChanges.isEmpty)
    }

    private final class SlideFixture: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        let driver = ReaderPagedPagingDriver()
        let collection: UICollectionView
        let window: UIWindow
        var inputs: ReaderPagedPagingInputs
        var selectionChanges: [Int] = []

        init(reversed: Bool = false) {
            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 800),
                collectionViewLayout: layout)
            window = UIWindow(frame: collection.frame)
            inputs = ReaderPagedPagingInputs(itemCount: 6, selectionIndex: 0, pagedTurnStyle: .slide,
                horizontalNavigationDirection: reversed ? .rightSwipeAdvances : .leftSwipeAdvances,
                pagerIdentity: ReaderPagedPagerIdentity(visibleView: 1, surfaceCount: 6, spreadCount: 6,
                    usesTwoPageSpread: false, layout: .zero),
                scrollAnimationRequest: nil, canBoundaryPageTurn: { _ in false }, onSelectionChange: { _ in },
                onBoundaryPageTurn: { _ in }, onScrollAnimationRequestConsumed: { _ in },
                pageTurnRestingBackgroundColor: { _ in .white }, pageTurnBackgroundColor: { _, _ in .gray },
                itemIndexForSelectionIndex: { reversed ? 5 - $0 : $0 },
                selectionIndexForItemIndex: { reversed ? 5 - $0 : $0 })
            super.init()
            inputs.onSelectionChange = { [weak self] in
                self?.inputs.selectionIndex = $0
                self?.selectionChanges.append($0)
            }
            collection.contentInsetAdjustmentBehavior = .never
            collection.isPagingEnabled = true
            collection.dataSource = self
            collection.delegate = self
            collection.register(ReaderPagedPageTurnCell.self, forCellWithReuseIdentifier: "page")
            let host = UIViewController()
            host.view.addSubview(collection)
            window.rootViewController = host
            window.isHidden = false
            collection.reloadData()
            collection.layoutIfNeeded()
            driver.requestSelectionScroll(in: collection, animated: false, inputs: inputs)
        }

        func close() {
            collection.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        func turn(_ zone: ReaderPagedTapZone) -> Bool {
            driver.animateAdjacentSelection(for: zone, in: collection, inputs: inputs)
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 6 }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath) -> CGSize { collectionView.bounds.size }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            driver.scrollViewDidScroll(scrollView, inputs: inputs)
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            driver.scrollViewDidEndScrollingAnimation(scrollView, inputs: inputs)
        }
    }
}
#endif
