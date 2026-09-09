import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("CommonTests: Reader Image Memory Cache", .serialized)
@MainActor
struct ReaderImageMemoryCacheTests {
    @Test func fullResolutionMangaImageRemainsInMemory() async throws {
        let bytes = try ReaderImageCacheFixture.png(width: 3638, height: 5102)
        let provider = ReaderImageCacheDataProvider(data: bytes)
        let pipeline = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: provider))
        let source = ReaderImageCacheFixture.source(0)

        let first = try await pipeline.image(for: source)
        #expect(first.cgImage?.width == 3638)
        #expect(first.cgImage?.height == 5102)
        #expect(pipeline.cachedImage(for: source) === first)
        let second = try await pipeline.image(for: source)
        #expect(second === first)
        #expect(await provider.callCount == 1)
        await pipeline.clearCache()
    }

    @Test func defaultBudgetAndSingleEntryLimit() {
        #expect(YamiboUIImagePipeline.defaultMemoryLimitBytes == 512 * 1024 * 1024)
        #expect(YamiboUIImagePipeline.defaultEntryCostLimit == 0.25)
    }

    @Test func injectedMemoryCacheClearsOnlyItsOwnPipeline() async throws {
        let provider = ReaderImageCacheDataProvider(data: try ReaderImageCacheFixture.png())
        let firstCache = YamiboUIImageMemoryCache()
        let first = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: provider), memoryCache: firstCache)
        let second = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: provider))
        let source = ReaderImageCacheFixture.source(0)
        _ = try await first.image(for: source)
        _ = try await second.image(for: source)

        await firstCache.removeAllCachedData()

        #expect(first.cachedImage(for: source) == nil)
        #expect(second.cachedImage(for: source) != nil)
        #expect(await firstCache.totalDiskUsageBytes() == 0)
        await second.clearCache()
    }

    @Test func sameSourceUsesEachPipelinesOwnImageData() async throws {
        let firstProvider = ReaderImageCacheDataProvider(data: try ReaderImageCacheFixture.png(width: 16))
        let secondProvider = ReaderImageCacheDataProvider(data: try ReaderImageCacheFixture.png(width: 32))
        let first = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: firstProvider))
        let second = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: secondProvider))
        let source = ReaderImageCacheFixture.source(0)

        #expect(try await first.image(for: source).cgImage?.width == 16)
        #expect(try await second.image(for: source).cgImage?.width == 32)
        #expect(first.cachedImage(for: source)?.cgImage?.width == 16)
        #expect(await firstProvider.callCount == 1)
        #expect(await secondProvider.callCount == 1)
    }

    @Test func singleEntryLimitUsesDecodedCostAndRejectsTheBoundary() async throws {
        let data = try ReaderImageCacheFixture.png()
        let cost = try await decodedCost(data)
        let source = ReaderImageCacheFixture.source(0)
        for (budget, fraction, accepted) in [(cost * 5, 0.1, false), (cost * 5, 0.25, true), (cost * 4, 0.25, false)] {
            let provider = ReaderImageCacheDataProvider(data: data)
            let pipeline = YamiboUIImagePipeline(
                core: YamiboImagePipeline(offlineImages: provider),
                memoryLimitBytes: budget, entryCostLimit: fraction
            )
            _ = try await pipeline.image(for: source)
            #expect((pipeline.cachedImage(for: source) != nil) == accepted)
            await pipeline.clearCache()
        }
    }

    @Test func multiplePagesCoexistThenEvictWithinBudgetAndClear() async throws {
        let data = try ReaderImageCacheFixture.png()
        let cost = try await decodedCost(data)
        let provider = ReaderImageCacheDataProvider(data: data)
        let pipeline = YamiboUIImagePipeline(
            core: YamiboImagePipeline(offlineImages: provider), memoryLimitBytes: cost * 7
        )
        let sources = (0..<10).map(ReaderImageCacheFixture.source)
        for source in sources.prefix(6) { _ = try await pipeline.image(for: source) }
        #expect(sources.prefix(6).allSatisfy { pipeline.cachedImage(for: $0) != nil })
        for source in sources.dropFirst(6) { _ = try await pipeline.image(for: source) }
        #expect(sources.filter { pipeline.cachedImage(for: $0) != nil }.count == 7)
        #expect(pipeline.cachedImage(for: sources[9]) != nil)
        await pipeline.clearCache()
        #expect(sources.allSatisfy { pipeline.cachedImage(for: $0) == nil })
        _ = try await pipeline.image(for: sources[9])
        #expect(await provider.callCount == 11)
        await pipeline.clearCache()
    }

    private func decodedCost(_ data: Data) async throws -> Int {
        let pipeline = YamiboUIImagePipeline(core: YamiboImagePipeline(offlineImages: ReaderImageCacheDataProvider(data: data)))
        let image = try await pipeline.image(for: ReaderImageCacheFixture.source(0))
        let cgImage = try #require(image.cgImage)
        await pipeline.clearCache()
        return cgImage.bytesPerRow * cgImage.height
    }
}

enum ReaderImageCacheFixture {
    static func source(_ index: Int) -> YamiboImageSource {
        YamiboImageSource(
            url: URL(string: "https://images.example.com/cache-\(index).png")!,
            offlineScope: YamiboImageOfflineScope(tid: "700")
        )
    }

    static func png(width: Int = 64, height: Int = 64) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

actor ReaderImageCacheDataProvider: YamiboOfflineImageDataProviding {
    let data: Data
    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []

    init(data: Data) { self.data = data }

    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data? {
        callCount += 1
        requestedURLs.append(url)
        return data
    }
}
