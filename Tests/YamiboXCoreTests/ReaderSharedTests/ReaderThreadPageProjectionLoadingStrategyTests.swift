import Foundation
import Testing
@testable import YamiboXCore

@Suite("ReaderSharedTests: Thread Page Projection Strategy", .serialized)
struct ReaderThreadPageProjectionLoadingStrategyTests {
    @Test func directAuthorIDUsesCachedAuthorScopedPageWithoutNetwork() async throws {
        let fixture = try await SharedThreadPageProjectionFixture()
        defer { fixture.cleanup() }
        try await fixture.cacheStore.saveThreadPage(
            sharedThreadPage(tid: "300", postID: "p-author", authorID: "42"),
            thread: ThreadIdentity(tid: "300"),
            pageNumber: 2,
            authorID: "42"
        )

        let loaded = try await fixture.loader.load(
            SharedThreadPageProjectionRequest(threadID: "300", view: 2, authorID: "42")
        )

        #expect(loaded.projection.identity.authorID == "42")
        #expect(loaded.projection.postIDs == ["p-author"])
        #expect(loaded.source == .online(sourceLoadedOnline: false))
        #expect(fixture.requests.isEmpty)
    }

    @Test func missingAuthorIDUsesCachedDiscoveryPageBeforeNetwork() async throws {
        let fixture = try await SharedThreadPageProjectionFixture()
        defer { fixture.cleanup() }
        try await fixture.cacheStore.saveThreadPage(
            sharedThreadPage(tid: "301", postID: "p-discovery", authorID: "77"),
            thread: ThreadIdentity(tid: "301"),
            pageNumber: 1,
            authorID: nil
        )
        try await fixture.cacheStore.saveThreadPage(
            sharedThreadPage(tid: "301", postID: "p-author", authorID: "77"),
            thread: ThreadIdentity(tid: "301"),
            pageNumber: 3,
            authorID: "77"
        )

        let loaded = try await fixture.loader.load(
            SharedThreadPageProjectionRequest(threadID: "301", view: 3)
        )

        #expect(loaded.projection.identity.authorID == "77")
        #expect(loaded.projection.postIDs == ["p-author"])
        #expect(fixture.requests.isEmpty)
    }

    @Test func onlineDiscoveryPrefersOnlyAuthorHTMLFact() async throws {
        let fixture = try await SharedThreadPageProjectionFixture()
        defer { fixture.cleanup() }
        fixture.setHandler { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let authorID = query.first(where: { $0.name == "authorid" })?.value
            if authorID == "88" {
                return SharedThreadPageProjectionResponse(html: sharedThreadHTML(tid: "302", postID: "9002", authorID: "88"))
            }
            return SharedThreadPageProjectionResponse(
                html: sharedThreadHTML(
                    tid: "302",
                    postID: "8002",
                    authorID: "44",
                    extraHTML: #"<a href="forum.php?mod=viewthread&tid=302&authorid=88">只看该作者</a>"#
                )
            )
        }

        let loaded = try await fixture.loader.load(
            SharedThreadPageProjectionRequest(threadID: "302", view: 5)
        )

        #expect(loaded.projection.identity.authorID == "88")
        #expect(loaded.projection.postIDs == ["9002"])
        #expect(fixture.requests.count == 2)
    }

    @Test func onlineDiscoveryFallsBackToFirstPostAuthor() async throws {
        let fixture = try await SharedThreadPageProjectionFixture()
        defer { fixture.cleanup() }
        fixture.setHandler { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let authorID = query.first(where: { $0.name == "authorid" })?.value
            return SharedThreadPageProjectionResponse(
                html: sharedThreadHTML(
                    tid: "303",
                    postID: authorID == nil ? "8003" : "9003",
                    authorID: authorID ?? "55"
                )
            )
        }

        let loaded = try await fixture.loader.load(
            SharedThreadPageProjectionRequest(threadID: "303", view: 4)
        )

        #expect(loaded.projection.identity.authorID == "55")
        #expect(loaded.projection.postIDs == ["9003"])
        #expect(fixture.requests.count == 2)
    }

    @Test func fingerprintHelperKeepsComponentShapeStable() {
        let page = ForumThreadPage(
            thread: ThreadIdentity(tid: "10"),
            title: "指纹测试",
            posts: [
                ForumThreadPost(
                    postID: "p1",
                    author: BlogReaderUser(uid: "u1", name: "作者"),
                    contentHTML: "<p>body</p>",
                    contentText: "body",
                    images: [
                        ForumThreadPostImage(url: "/a.jpg"),
                        ForumThreadPostImage(url: "https://img.example/b.jpg")
                    ]
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: 2, totalPages: 7)
        )

        #expect(ReaderThreadPageProjectionFingerprint.fingerprint(
            page: page,
            identityComponents: ["10", "2", "99"]
        ) == "489252183f6074f6")
    }
}

private struct SharedThreadPageProjectionRequest: ReaderThreadPageProjectionRequesting {
    var threadID: String
    var view: Int
    var authorID: String?

    init(threadID: String, view: Int = 1, authorID: String? = nil) {
        self.threadID = threadID
        self.view = max(1, view)
        self.authorID = authorID
    }
}

private struct SharedThreadPageProjectionIdentity: ReaderThreadPageProjectionIdentifying {
    var threadID: String
    var view: Int
    var authorID: String?
}

private struct SharedThreadPageProjection: Hashable, Sendable {
    var identity: SharedThreadPageProjectionIdentity
    var fingerprint: String
    var postIDs: [String]
}

private struct SharedThreadPageProjectionAdapter: ReaderThreadPageProjectionAdapter {
    typealias Request = SharedThreadPageProjectionRequest
    typealias Identity = SharedThreadPageProjectionIdentity
    typealias Projection = SharedThreadPageProjection

    let client: YamiboClient
    let forumCacheStore: ForumCacheStore
    let authorScopeErrorContext = "shared author scope"

    func makeIdentity(request: SharedThreadPageProjectionRequest, authorID: String) -> SharedThreadPageProjectionIdentity {
        SharedThreadPageProjectionIdentity(
            threadID: request.threadID,
            view: request.view,
            authorID: authorID
        )
    }

    func offlineSourcePage(
        for request: SharedThreadPageProjectionRequest
    ) async -> ReaderProjectionOfflineSourcePageLoad<SharedThreadPageProjectionIdentity, ForumThreadPage>? {
        nil
    }

    func fingerprintIdentityComponents(for identity: SharedThreadPageProjectionIdentity) -> [String] {
        [
            identity.threadID,
            String(identity.view),
            identity.authorID ?? ""
        ]
    }

    func cachedProjection(for identity: SharedThreadPageProjectionIdentity) async -> SharedThreadPageProjection? {
        nil
    }

    func isReusableProjection(
        _ projection: SharedThreadPageProjection,
        identity: SharedThreadPageProjectionIdentity,
        fingerprint: String
    ) -> Bool {
        projection.identity == identity && projection.fingerprint == fingerprint
    }

    func buildProjection(
        sourcePage: ForumThreadPage,
        identity: SharedThreadPageProjectionIdentity,
        fingerprint: String
    ) throws -> SharedThreadPageProjection {
        SharedThreadPageProjection(
            identity: identity,
            fingerprint: fingerprint,
            postIDs: sourcePage.posts.map(\.postID)
        )
    }

    func saveProjection(_ projection: SharedThreadPageProjection) async throws {}
}

private final class SharedThreadPageProjectionFixture: @unchecked Sendable {
    let testID = UUID().uuidString
    let rootDirectory: URL
    let cacheStore: ForumCacheStore
    let loader: ReaderProjectionLoader<ReaderThreadPageProjectionLoadingStrategy<SharedThreadPageProjectionAdapter>>
    private let session: URLSession

    init() async throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YamiboXSharedProjectionTests-\(testID)", isDirectory: true)
        try? FileManager.default.removeItem(at: rootDirectory)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        cacheStore = ForumCacheStore(rootDirectory: rootDirectory)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedThreadPageProjectionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Shared-Projection-Test-ID": testID]
        session = URLSession(configuration: configuration)

        loader = ReaderProjectionLoader(
            strategy: ReaderThreadPageProjectionLoadingStrategy(
                adapter: SharedThreadPageProjectionAdapter(
                    client: YamiboClient(session: session, userAgent: "SharedProjectionTests"),
                    forumCacheStore: cacheStore
                )
            )
        )
    }

    var requests: [URLRequest] {
        SharedThreadPageProjectionURLProtocol.requests(for: testID)
    }

    func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> SharedThreadPageProjectionResponse) {
        SharedThreadPageProjectionURLProtocol.setHandler(for: testID, handler: handler)
    }

    func cleanup() {
        SharedThreadPageProjectionURLProtocol.reset(testID: testID)
    }
}

private struct SharedThreadPageProjectionResponse: Sendable {
    var html: String
}

private final class SharedThreadPageProjectionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var handlersByTestID: [String: @Sendable (URLRequest) throws -> SharedThreadPageProjectionResponse] = [:]
    nonisolated(unsafe) private static var recordedRequestsByTestID: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func setHandler(
        for testID: String,
        handler: @escaping @Sendable (URLRequest) throws -> SharedThreadPageProjectionResponse
    ) {
        withLockedState {
            handlersByTestID[testID] = handler
            recordedRequestsByTestID[testID] = []
        }
    }

    static func reset(testID: String) {
        withLockedState {
            handlersByTestID.removeValue(forKey: testID)
            recordedRequestsByTestID.removeValue(forKey: testID)
        }
    }

    static func requests(for testID: String) -> [URLRequest] {
        withLockedState { recordedRequestsByTestID[testID] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let testID = request.value(forHTTPHeaderField: "X-Shared-Projection-Test-ID")
        let handler: (@Sendable (URLRequest) throws -> SharedThreadPageProjectionResponse)? = Self.withLockedState {
            if let testID {
                Self.recordedRequestsByTestID[testID, default: []].append(request)
                return Self.handlersByTestID[testID]
            }
            return nil
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let output = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(output.html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private func sharedThreadPage(tid: String, postID: String, authorID: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "Thread \(tid)",
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: authorID, name: "作者\(authorID)"),
                contentHTML: "正文",
                contentText: "正文"
            )
        ]
    )
}

private func sharedThreadHTML(
    tid: String,
    postID: String,
    authorID: String,
    extraHTML: String = ""
) -> String {
    """
    <html>
      <head><title>Thread \(tid)</title></head>
      <body>
        \(extraHTML)
        <div id="post_\(postID)">
          <div class="authi"><a href="home.php?mod=space&uid=\(authorID)">作者\(authorID)</a></div>
          <div id="postmessage_\(postID)" class="message">正文</div>
        </div>
      </body>
    </html>
    """
}
