import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Reader Projection Cache App Context", .serialized)
struct MangaReaderTestsReaderProjectionCacheAppContext {
    @Test func appContextReaderProjectionLoaderUsesSharedStoreAcrossLoaderInstances() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }

        let counter = MangaReaderProjectionCacheRequestCounter()
        harness.setHandler { request in
            counter.increment()
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "ChapterAgent/Context")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=chapter")
            return MangaReaderDataTestResponse(html: """
            <html>
              <head><title>缓存章节 第1话 - 中文百合漫画区 - 百合会</title></head>
              <body>
                <div id="postmessage_9001">
                  <div class="message">
                    <img src="https://img.example.com/context-1.jpg" />
                  </div>
                </div>
              </body>
            </html>
            """)
        }

        let defaults = try #require(UserDefaults(suiteName: "manga-projection-context-\(UUID().uuidString)"))
        let sessionStore = SessionStore(defaults: defaults, key: "session")
        try await sessionStore.save(
            SessionState(
                cookie: "auth=chapter",
                userAgent: "ChapterAgent/Context",
                isLoggedIn: true
            )
        )

        let projectionStore = try makeTestMangaReaderProjectionStore(rootDirectory: try makeTemporaryAppContextReaderProjectionDirectory())
        let appContext = YamiboAppContext(
            sessionStore: sessionStore,
            mangaReaderProjectionStore: projectionStore,
            session: harness.session
        )
        let request = MangaReaderProjectionRequest(threadID: "900", view: 5, authorID: "42")

        let firstLoader = await appContext.makeMangaReaderProjectionLoader()
        let first = try await firstLoader.loadReaderProjection(request)
        let secondLoader = await appContext.makeMangaReaderProjectionLoader()
        let second = try await secondLoader.loadReaderProjection(request)

        #expect(first.tid == "900")
        #expect(second.tid == "900")
        #expect(first.imageURLs == second.imageURLs)
        #expect(counter.value == 1)
    }
}

private final class MangaReaderProjectionCacheRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func makeTemporaryAppContextReaderProjectionDirectory() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}
