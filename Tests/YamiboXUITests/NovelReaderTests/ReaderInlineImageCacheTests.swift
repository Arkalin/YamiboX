#if os(iOS)
import UIKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class ReaderInlineImageCacheTests: XCTestCase {
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
        } catch YamiboError.invalidImageData {
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

private func testImageData(color: UIColor) -> Data {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
        color.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).fill()
    }
    return image.pngData()!
}
#endif
