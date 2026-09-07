#if os(iOS)
import UIKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class ReaderInlineImageCacheTests: XCTestCase {
    @MainActor
    func testInlineImageFailureShowsRetryAndRecoversAfterRepeatedFailure() async throws {
        let source = YamiboImageSource(
            url: URL(string: "https://img.example.com/inline-retry.jpg")!,
            offlineScope: YamiboImageOfflineScope(tid: "42")
        )
        let bytes = SequencedOfflineImageBytes(outputs: [
            Data([0, 1, 2]), Data([0, 1, 2]), testImageData(color: .blue)
        ])
        let view = NovelReaderVerticalViewportImageView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            pipeline: makeUIPipeline(bytes: bytes)
        )
        view.configure(source: source, title: "Chapter", isLiked: false, onTap: { _, _ in })
        let failureLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first)
        let indicator = try XCTUnwrap(view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
        try await waitUntil { !failureLabel.isHidden }
        let retry = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let details = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "load-failure-details"
        })
        XCTAssertFalse(details.isHidden)
        XCTAssertFalse(retry.isHidden)
        XCTAssertFalse(indicator.isAnimating)
        XCTAssertNil(view.imageTapPayloadIfHit(at: CGPoint(x: 160, y: 240)))

        for height in [CGFloat(100), CGFloat(30)] {
            view.frame.size.height = height
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertTrue(view.bounds.contains(details.frame))
            XCTAssertTrue(view.bounds.contains(retry.frame))
            XCTAssertGreaterThanOrEqual(details.frame.minY, retry.frame.maxY)
        }
        view.frame.size.height = 480
        view.setNeedsLayout()
        for attempt in 0..<2 {
            view.layoutIfNeeded()
            XCTAssertGreaterThanOrEqual(retry.bounds.height, 44)
            XCTAssertTrue(view.bounds.contains(retry.frame))
            XCTAssertFalse(failureLabel.frame.intersects(retry.frame))
            XCTAssertGreaterThanOrEqual(details.frame.minY, retry.frame.maxY)
            XCTAssertGreaterThanOrEqual(details.bounds.height, 44)
            XCTAssertTrue(view.bounds.contains(details.frame))
            let hit = view.hitTest(retry.center, with: nil)
            XCTAssertTrue(hit?.isDescendant(of: retry) == true)
            let action = try XCTUnwrap(retry.actions(forTarget: view, forControlEvent: .touchUpInside)?.first)
            _ = view.perform(NSSelectorFromString(action))
            XCTAssertTrue(retry.isHidden)
            XCTAssertTrue(details.isHidden)
            XCTAssertTrue(failureLabel.isHidden)
            XCTAssertTrue(indicator.isAnimating)
            if attempt == 0 {
                try await waitUntil { !failureLabel.isHidden }
                XCTAssertFalse(retry.isHidden)
            } else {
                try await waitUntil { view.imageTapPayloadIfHit(at: CGPoint(x: 160, y: 240)) != nil }
            }
        }

        XCTAssertTrue(retry.isHidden)
        XCTAssertTrue(details.isHidden)
        XCTAssertTrue(failureLabel.isHidden)
        XCTAssertFalse(indicator.isAnimating)
        XCTAssertEqual(view.imageTapPayloadIfHit(at: CGPoint(x: 160, y: 240))?.url, source.url)
        let callCount = await bytes.loadCallCount()
        XCTAssertEqual(callCount, 3)
    }

    @MainActor
    func testReusingFailedInlineImageClearsDetailsBeforeNewImageLoads() async throws {
        let scope = YamiboImageOfflineScope(tid: "42")
        let first = YamiboImageSource(url: URL(string: "https://img.example.com/old.jpg")!, offlineScope: scope)
        let second = YamiboImageSource(url: URL(string: "https://img.example.com/new.jpg")!, offlineScope: scope)
        let bytes = SequencedOfflineImageBytes(outputs: [Data([0, 1]), testImageData(color: .blue)])
        let view = NovelReaderVerticalViewportImageView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480), pipeline: makeUIPipeline(bytes: bytes)
        )
        view.configure(source: first, title: nil, isLiked: false, onTap: { _, _ in })
        let details = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "load-failure-details"
        })
        try await waitUntil { !details.isHidden }
        view.configure(source: second, title: nil, isLiked: false, onTap: { _, _ in })
        XCTAssertTrue(details.isHidden)
        try await waitUntil { view.imageTapPayloadIfHit(at: CGPoint(x: 160, y: 240))?.url == second.url }
        XCTAssertTrue(details.isHidden)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for inline image state")
    }

    @MainActor
    func testPrefetchWarmsDisplayCacheUsingOfflineBytes() async throws {
        let source = YamiboImageSource(
            url: URL(string: "https://img.example.com/prefetched.png")!,
            offlineScope: YamiboImageOfflineScope(tid: "42")
        )
        let bytes = SequencedOfflineImageBytes(outputs: [testImageData(color: .red)])
        let pipeline = makeUIPipeline(bytes: bytes)
        let prefetched = try await pipeline.image(for: source, priority: .low)
        let displayed = try await pipeline.image(for: source)
        XCTAssertTrue(prefetched === displayed)
        let calls = await bytes.loadCallCount()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCancellingPrefetchDoesNotCancelConcurrentDisplayLoad() async throws {
        let source = YamiboImageSource(
            url: URL(string: "https://img.example.com/shared-prefetch.png")!,
            offlineScope: YamiboImageOfflineScope(tid: "42")
        )
        let bytes = BlockingOfflineImageBytes(data: testImageData(color: .blue))
        let pipeline = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: bytes))
        let prefetch = Task { try await pipeline.image(for: source, priority: .low) }
        let display = Task { try await pipeline.image(for: source) }
        await bytes.waitUntilStarted()
        // Both main-actor subscribers enter the pipeline before cancellation.
        for _ in 0..<10 { await Task.yield() }
        prefetch.cancel()
        await bytes.release()
        let image = try await display.value
        _ = await prefetch.result
        XCTAssertTrue(pipeline.cachedImage(for: source) === image)
        let calls = await bytes.callCount
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testMemoryCacheUsesURLIdentityAcrossReferers() async throws {
        let imageURL = URL(string: "https://img.example.com/shared.jpg")!
        let scope = try XCTUnwrap(YamiboImageOfflineScope(tid: "42"))
        let firstSource = YamiboImageSource(
            url: imageURL,
            refererPageURL: URL(string: "https://bbs.yamibo.com/forum.php?tid=42"),
            offlineScope: scope
        )
        let secondSource = YamiboImageSource(
            url: imageURL,
            refererPageURL: URL(string: "https://bbs.yamibo.com/forum.php?tid=43"),
            offlineScope: scope
        )
        let bytes = SequencedOfflineImageBytes(outputs: [
            testImageData(color: .red),
            testImageData(color: .blue)
        ])
        let pipeline = makeUIPipeline(bytes: bytes)

        let firstImage = try await pipeline.image(for: firstSource)
        let secondImage = try await pipeline.image(for: secondSource)

        XCTAssertTrue(pipeline.cachedImage(for: firstSource) === firstImage)
        XCTAssertTrue(pipeline.cachedImage(for: secondSource) === firstImage)
        XCTAssertTrue(firstImage === secondImage)
        let callCount = await bytes.loadCallCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testImagePipelineDeduplicatesConcurrentLoads() async throws {
        let source = YamiboImageSource(
            url: URL(string: "https://img.example.com/dedupe.jpg")!,
            refererPageURL: URL(string: "https://bbs.yamibo.com/forum.php?tid=42")!,
            offlineScope: YamiboImageOfflineScope(tid: "42")
        )
        let bytes = SequencedOfflineImageBytes(
            outputs: [testImageData(color: .red)],
            delayNanoseconds: 50_000_000
        )
        let pipeline = makeUIPipeline(bytes: bytes)

        async let first = pipeline.image(for: source)
        async let second = pipeline.image(for: source)
        _ = try await [first, second]

        let callCount = await bytes.loadCallCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testImagePipelineDoesNotCacheDecodeFailures() async throws {
        let source = YamiboImageSource(
            url: URL(string: "https://img.example.com/retry.jpg")!,
            offlineScope: YamiboImageOfflineScope(tid: "42")
        )
        let bytes = SequencedOfflineImageBytes(outputs: [
            Data([0, 1, 2]),
            testImageData(color: .blue)
        ])
        let pipeline = makeUIPipeline(bytes: bytes)

        do {
            _ = try await pipeline.image(for: source)
            XCTFail("Expected invalid image data")
        } catch where (LoadDiagnosticError.classificationError(error) as? YamiboError) == .invalidImageData {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(pipeline.cachedImage(for: source))

        _ = try await pipeline.image(for: source)

        XCTAssertNotNil(pipeline.cachedImage(for: source))
        let callCount = await bytes.loadCallCount()
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    private func makeUIPipeline(bytes: SequencedOfflineImageBytes) -> YamiboUIImagePipeline {
        YamiboUIImagePipeline(
            core: YamiboImagePipeline(offlineImages: bytes)
        )
    }
}

/// Feeds sequenced bytes through the offline-lookup path so tests never
/// touch the network or the shared disk cache.
private actor SequencedOfflineImageBytes: YamiboOfflineImageDataProviding {
    private var outputs: [Data]
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(outputs: [Data], delayNanoseconds: UInt64 = 0) {
        self.outputs = outputs
        self.delayNanoseconds = delayNanoseconds
    }

    func offlineImageData(url _: URL, scope _: YamiboImageOfflineScope) async -> Data? {
        callCount += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return outputs.isEmpty ? nil : outputs.removeFirst()
    }

    func loadCallCount() -> Int {
        callCount
    }
}

private actor BlockingOfflineImageBytes: YamiboOfflineImageDataProviding {
    let data: Data
    var callCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?

    init(data: Data) { self.data = data }

    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data? {
        callCount += 1
        startedWaiter?.resume()
        startedWaiter = nil
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return data
    }

    func waitUntilStarted() async {
        if callCount == 0 {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private func testImageData(color: UIColor) -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
        color.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).fill()
    }
    return image.pngData()!
}
#endif
