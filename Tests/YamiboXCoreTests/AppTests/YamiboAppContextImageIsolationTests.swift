import Foundation
import Testing
@testable import YamiboXCore

@Suite("AppTests: Image Dependency Isolation")
struct YamiboAppContextImageIsolationTests {
    @Test func creatingAnotherContextDoesNotReplaceOfflineImageProvider() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            Issue.record("An offline image should not reach the network")
            return MangaReaderDataTestResponse(data: Data([9]))
        }
        let first = try ImageContextFixture(imageSession: harness.session)
        defer { first.cleanup() }
        let source = try makeSource(offline: true)
        try await first.retainOfflineImage(Data([1]), source: source)

        let second = try ImageContextFixture(imageSession: harness.session)
        defer { second.cleanup() }
        try await second.retainOfflineImage(Data([2]), source: source)

        #expect(try await first.context.imagePipeline.data(for: source) == Data([1]))
        #expect(try await second.context.imagePipeline.data(for: source) == Data([2]))
        #expect(try await first.context.accountDependencies.imagePipeline.data(for: source) == Data([1]))
        #expect(try await first.context.mangaReaderDependencies.imagePipeline.data(for: source) == Data([1]))
        #expect(try await first.context.novelReaderDependencies.imagePipeline.data(for: source) == Data([1]))
        #expect(harness.requests.isEmpty)
    }

    @Test func contextsUseTheirOwnSessionsAndClearingOneCacheKeepsTheOther() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? "missing"
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Agent-\(cookie)")
            return MangaReaderDataTestResponse(data: Data(cookie.utf8))
        }
        let first = try ImageContextFixture(imageSession: harness.session)
        defer { first.cleanup() }
        let second = try ImageContextFixture(imageSession: harness.session)
        defer { second.cleanup() }
        try await first.context.sessionStore.save(SessionState(cookie: "auth=first", userAgent: "Agent-auth=first"))
        try await second.context.sessionStore.save(SessionState(cookie: "auth=second", userAgent: "Agent-auth=second"))
        let source = try makeSource(offline: false)

        #expect(try await first.context.imagePipeline.data(for: source) == Data("auth=first".utf8))
        try await waitForCachedData(first.context.imagePipeline, source: source)
        #expect(try await second.context.imagePipeline.data(for: source) == Data("auth=second".utf8))
        try await waitForCachedData(second.context.imagePipeline, source: source)
        #expect(await first.context.settingsDependencies.ordinaryImageCacheUsageBytes() == 10)
        #expect(await second.context.settingsDependencies.ordinaryImageCacheUsageBytes() == 11)

        await first.context.settingsDependencies.clearOrdinaryImageCache()

        #expect(first.context.imagePipeline.cachedData(for: source) == nil)
        #expect(await first.context.settingsDependencies.ordinaryImageCacheUsageBytes() == 0)
        #expect(second.context.imagePipeline.cachedData(for: source) == Data("auth=second".utf8))
        #expect(await second.context.settingsDependencies.ordinaryImageCacheUsageBytes() == 11)
        #expect(harness.requests.count == 2)
        await second.context.settingsDependencies.clearOrdinaryImageCache()
    }
}

private struct ImageContextFixture {
    let context: YamiboAppContext
    let root: URL
    let suiteName: String

    init(imageSession: URLSession) throws {
        suiteName = "image-context-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults),
            grdbRootDirectory: root.appendingPathComponent("data", isDirectory: true),
            cachesRootDirectory: root.appendingPathComponent("caches", isDirectory: true),
            clearsWebDataOnReset: false,
            imageSession: imageSession
        )
    }

    func retainOfflineImage(_ data: Data, source: YamiboImageSource) async throws {
        try await context.offlineCacheStore.saveOfflineImageData(data, for: source.url)
        try await context.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "Book",
            tid: "100",
            chapterTitle: "Chapter",
            imageURLs: [source.url],
            sourcePage: ForumThreadPage(thread: ThreadIdentity(tid: "100"), title: "Chapter", posts: [])
        ))
    }

    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeSource(offline: Bool) throws -> YamiboImageSource {
    YamiboImageSource(
        url: try #require(URL(string: "https://bbs.yamibo.com/data/attachment/forum/image-context.jpg")),
        offlineScope: offline ? YamiboImageOfflineScope(tid: "100", ownerName: "Book") : nil
    )
}

private func waitForCachedData(_ pipeline: YamiboImagePipeline, source: YamiboImageSource) async throws {
    for _ in 0..<200 {
        if pipeline.cachedData(for: source) != nil { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ImageContextTestError.cacheWriteTimedOut
}

private enum ImageContextTestError: Error {
    case cacheWriteTimedOut
}
