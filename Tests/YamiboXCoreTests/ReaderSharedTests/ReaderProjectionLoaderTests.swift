import Foundation
import Testing
@testable import YamiboXCore

@Suite("ReaderSharedTests: Projection Loader", .serialized)
struct ReaderProjectionLoaderTests {
    @Test func onlineCacheHitReusesProjectionWithoutDeriving() async throws {
        let state = ReaderProjectionLoaderTestState()
        state.seed(TestProjection(id: "42", fingerprint: "online-body", body: "cached"))
        let loader = ReaderProjectionLoader(strategy: TestProjectionLoadingStrategy(state: state))

        let loaded = try await loader.load(TestProjectionRequest(id: "42", onlineBody: "online-body"))

        #expect(loaded.projection.body == "cached")
        #expect(state.deriveCount == 0)
        #expect(state.saveCount == 0)
        #expect(loaded.source == .online(sourceLoadedOnline: true))
    }

    @Test func cacheMissDerivesAndSavesProjection() async throws {
        let state = ReaderProjectionLoaderTestState()
        let loader = ReaderProjectionLoader(strategy: TestProjectionLoadingStrategy(state: state))

        let loaded = try await loader.load(TestProjectionRequest(id: "43", onlineBody: "fresh-body"))

        #expect(loaded.projection == TestProjection(id: "43", fingerprint: "fresh-body", body: "fresh-body"))
        #expect(state.deriveCount == 1)
        #expect(state.saveCount == 1)
        #expect(state.cachedProjection(id: "43") == loaded.projection)
    }

    @Test func ignoringCacheSkipsReadButStillSavesProjection() async throws {
        let state = ReaderProjectionLoaderTestState()
        state.seed(TestProjection(id: "44", fingerprint: "fresh-body", body: "stale"))
        let loader = ReaderProjectionLoader(strategy: TestProjectionLoadingStrategy(state: state))

        let loaded = try await loader.load(
            TestProjectionRequest(id: "44", onlineBody: "fresh-body"),
            ignoresCache: true
        )

        #expect(loaded.projection.body == "fresh-body")
        #expect(state.cacheReadCount == 0)
        #expect(state.deriveCount == 1)
        #expect(state.saveCount == 1)
    }

    @Test func eligibleOnlineErrorFallsBackToOfflineSourcePage() async throws {
        let state = ReaderProjectionLoaderTestState()
        let loader = ReaderProjectionLoader(strategy: TestProjectionLoadingStrategy(state: state))

        let loaded = try await loader.load(
            TestProjectionRequest(
                id: "45",
                onlineBody: "online-body",
                onlineError: .offline,
                offlineBody: "offline-body"
            )
        )

        #expect(loaded.projection == TestProjection(id: "45", fingerprint: "offline-body", body: "offline-body"))
        #expect(loaded.source == .offlineFallback(updatedAt: TestProjectionRequest.offlineUpdatedAt))
        #expect(state.saveCount == 1)
    }

    @Test func nonEligibleOnlineErrorKeepsOriginalFailure() async throws {
        let state = ReaderProjectionLoaderTestState()
        let loader = ReaderProjectionLoader(strategy: TestProjectionLoadingStrategy(state: state))

        await #expect(throws: YamiboError.self) {
            _ = try await loader.load(
                TestProjectionRequest(
                    id: "46",
                    onlineBody: "online-body",
                    onlineError: .parser,
                    offlineBody: "offline-body"
                )
            )
        }
        #expect(state.deriveCount == 0)
        #expect(state.saveCount == 0)
    }
}

private struct TestProjectionRequest: Sendable {
    static let offlineUpdatedAt = Date(timeIntervalSince1970: 1_772_000_000)

    var id: String
    var onlineBody: String
    var onlineError: TestProjectionOnlineError?
    var offlineBody: String?
}

private enum TestProjectionOnlineError: Sendable {
    case offline
    case parser
}

private struct TestProjection: Hashable, Sendable {
    var id: String
    var fingerprint: String
    var body: String
}

private final class ReaderProjectionLoaderTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [String: TestProjection] = [:]
    private var _cacheReadCount = 0
    private var _deriveCount = 0
    private var _saveCount = 0

    var cacheReadCount: Int {
        lock.withLock { _cacheReadCount }
    }

    var deriveCount: Int {
        lock.withLock { _deriveCount }
    }

    var saveCount: Int {
        lock.withLock { _saveCount }
    }

    func seed(_ projection: TestProjection) {
        lock.withLock {
            cached[projection.id] = projection
        }
    }

    func cachedProjection(id: String) -> TestProjection? {
        lock.withLock {
            _cacheReadCount += 1
            return cached[id]
        }
    }

    func derive(id: String, body: String, fingerprint: String) throws -> TestProjection {
        try lock.withLock {
            _deriveCount += 1
            if body == "unparseable" {
                throw YamiboError.parsingFailed(context: "test projection")
            }
            return TestProjection(id: id, fingerprint: fingerprint, body: body)
        }
    }

    func save(_ projection: TestProjection) {
        lock.withLock {
            _saveCount += 1
            cached[projection.id] = projection
        }
    }
}

private struct TestProjectionLoadingStrategy: ReaderProjectionLoadingStrategy {
    typealias Request = TestProjectionRequest
    typealias Identity = String
    typealias Projection = TestProjection
    typealias SourcePage = String

    let state: ReaderProjectionLoaderTestState

    func identity(for request: TestProjectionRequest, ignoresCache: Bool) async throws -> String {
        request.id
    }

    func onlineSourcePage(
        for request: TestProjectionRequest,
        identity: String,
        ignoresCache: Bool
    ) async throws -> ReaderProjectionSourcePageLoad<String> {
        switch request.onlineError {
        case .offline:
            throw YamiboError.offline
        case .parser:
            throw YamiboError.parsingFailed(context: "test projection")
        case nil:
            return ReaderProjectionSourcePageLoad(sourcePage: request.onlineBody, loadedOnline: true)
        }
    }

    func offlineSourcePage(
        for request: TestProjectionRequest
    ) async -> ReaderProjectionOfflineSourcePageLoad<String, String>? {
        guard let offlineBody = request.offlineBody else { return nil }
        return ReaderProjectionOfflineSourcePageLoad(
            sourcePage: offlineBody,
            identity: request.id,
            updatedAt: TestProjectionRequest.offlineUpdatedAt
        )
    }

    func fingerprint(sourcePage: String, identity: String) -> String {
        sourcePage
    }

    func cachedProjection(for identity: String) async -> TestProjection? {
        state.cachedProjection(id: identity)
    }

    func isReusableProjection(_ projection: TestProjection, identity: String, fingerprint: String) -> Bool {
        projection.id == identity && projection.fingerprint == fingerprint
    }

    func deriveProjection(sourcePage: String, identity: String, fingerprint: String) throws -> TestProjection {
        try state.derive(id: identity, body: sourcePage, fingerprint: fingerprint)
    }

    func saveProjection(_ projection: TestProjection) async throws {
        state.save(projection)
    }
}
