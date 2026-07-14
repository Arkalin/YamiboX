import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

private final class YamiboAccountTestURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: YamiboAccountTestError.missingHandler)
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum YamiboAccountTestError: Error {
    case missingHandler
}

@Test func yamiboProfileParserExtractsIdentityCreditsAndLogoutToken() throws {
    let profile = try YamiboProfileParser.parse(profileHTML())

    #expect(profile.uid == "535977")
    #expect(profile.username == "arkalin")
    #expect(profile.userGroup == "百合花蕾")
    #expect(profile.totalPoints == 155)
    #expect(profile.points == 29)
    #expect(profile.partner == 377)
    #expect(profile.avatarURL?.absoluteString == "https://bbs.yamibo.com/uc_server/data/avatar/000/53/59/77_avatar_big.jpg")
    #expect(profile.avatarBackgroundURL?.absoluteString == "https://bbs.yamibo.com/uc_server/data/avatar/000/53/59/77_avatar_big.jpg")
    #expect(profile.formHash == "abc123")
}

@Test func forumCreditProgressUsesLocalNextUserGroupThreshold() {
    let profile = YamiboProfile(
        uid: "535977",
        username: "arkalin",
        userGroup: "百合花蕾",
        points: 29,
        partner: 377,
        totalPoints: 155
    )

    let progress = YamiboUserGroups.progress(for: profile)

    #expect(progress.currentGroupName == "百合花蕾")
    #expect(progress.currentTotalPoints == 155)
    #expect(progress.targetTotalPoints == 400)
    #expect(progress.fraction == 0.3875)
}

@Test func yamiboAccountServiceLogsInWithNativeFormAndCachesProfile() async throws {
    clearSharedYamiboCookies()
    defer {
        YamiboAccountTestURLProtocol.handler = nil
        clearSharedYamiboCookies()
    }

    let session = makeAccountTestSession()
    let suiteName = "yamibo-account-service-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let sessionDefaults = try #require(UserDefaults(suiteName: suiteName))
    let profileDefaults = try #require(UserDefaults(suiteName: suiteName))
    let sessionStore = SessionStore(defaults: sessionDefaults, key: "session")
    let profileStore = YamiboProfileStore(defaults: profileDefaults, key: "profile")
    let service = YamiboAccountService(
        session: session,
        sessionStore: sessionStore,
        profileStore: profileStore,
        userAgent: "Test-UA"
    )

    var postedBody = ""
    YamiboAccountTestURLProtocol.handler = { request in
        switch (request.url?.path, request.httpMethod) {
        case ("/member.php", "GET"):
            return httpResponse(
                url: request.url!,
                body: loginFormHTML(),
                headers: ["Set-Cookie": "EeqY_2132_saltkey=salt; Path=/; Domain=bbs.yamibo.com"]
            )
        case ("/member.php", "POST"):
            postedBody = String(data: request.httpBodyStreamData(), encoding: .utf8) ?? ""
            storeYamiboCookies(
                ["Set-Cookie": "EeqY_2132_auth=token; Path=/; Domain=bbs.yamibo.com"],
                for: request.url!
            )
            return httpResponse(
                url: request.url!,
                body: "<html><body>欢迎回来</body></html>",
                headers: ["Set-Cookie": "EeqY_2132_auth=token; Path=/; Domain=bbs.yamibo.com"]
            )
        case ("/home.php", "GET"):
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("EeqY_2132_auth=token") == true)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test-UA")
            return httpResponse(url: request.url!, body: profileHTML())
        default:
            Issue.record("Unexpected request \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
            return httpResponse(url: request.url!, body: "", statusCode: 500)
        }
    }

    let profile = try await service.login(
        YamiboLoginRequest(
            username: " arkalin ",
            password: "secret",
            questionID: "1",
            answer: "answer"
        )
    )
    let sessionState = await sessionStore.load()
    let cachedProfile = await profileStore.load()

    #expect(postedBody.contains("username=arkalin"))
    #expect(postedBody.contains("password=secret"))
    #expect(postedBody.contains("questionid=1"))
    #expect(postedBody.contains("answer=answer"))
    #expect(profile.uid == "535977")
    #expect(sessionState.isLoggedIn)
    #expect(sessionState.accountUID == "535977")
    #expect(SessionState.hasAuthenticationCookie(sessionState.cookie))
    #expect(cachedProfile == profile)
}

@Test func yamiboAccountServiceClearLocalAuthenticationPreservesFavoriteLibraryAndMangaOfflineCache() async throws {
    let suiteName = "yamibo-account-signout-preserves-local-data-\(UUID().uuidString)"
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yamibo-account-signout-preserves-local-data-\(UUID().uuidString)", isDirectory: true)
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let sessionStore = SessionStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "session")
    let profileStore = YamiboProfileStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "profile")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try #require(UserDefaults(suiteName: suiteName)),
        key: "local-favorites"
    )
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: rootDirectory)
    let service = YamiboAccountService(
        session: makeAccountTestSession(),
        sessionStore: sessionStore,
        profileStore: profileStore
    )
    var favoriteLibrary = FavoriteLibraryDocument()
    let favoriteItem = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "970"),
        title: "退出保留漫画",
        locations: [.category(favoriteLibrary.defaultCategory.id)]
    )
    favoriteLibrary.upsertItem(favoriteItem)
    let favoriteURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=970&mobile=2"))
    let imageURL = try #require(URL(string: "https://img.example.com/signout-offline.jpg"))

    try await sessionStore.save(SessionState(cookie: "sid=1; EeqY_2132_auth=token", isLoggedIn: true, accountUID: "535977"))
    try await profileStore.save(YamiboProfile(
        uid: "535977",
        username: "arkalin",
        userGroup: "百合花蕾",
        points: 29,
        partner: 377,
        totalPoints: 155
    ))
    try await localFavoriteLibraryStore.save(favoriteLibrary)
    try await offlineStore.saveOfflineImageData(Data([7]), for: imageURL)
    try await offlineStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
        ownerName: favoriteItem.title,
        tid: "970",
        chapterTitle: "第970话",
        imageURLs: [imageURL],
        sourcePage: makeAccountOfflineSourcePage(tid: "970")
    ))
    _ = try await offlineStore.enqueueMangaOfflineCacheWork(MangaOfflineCacheWorkRequest(
        ownerName: favoriteItem.title,
        tid: "971",
        chapterTitle: "第971话",
        targetImageURLs: [imageURL]
    ))

    try await service.clearLocalAuthentication()

    #expect(await sessionStore.load() == SessionState())
    #expect(await profileStore.load() == nil)
    #expect(try await localFavoriteLibraryStore.load() == favoriteLibrary)
    #expect(await offlineStore.mangaOfflineCacheMembership(ownerName: favoriteItem.title, tid: "970") != nil)
    #expect(await offlineStore.mangaQueueWork(ownerName: favoriteItem.title, tid: "971") != nil)
    #expect(await offlineStore.offlineImageData(for: imageURL) == Data([7]))
}

private func makeAccountOfflineSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

private func makeAccountTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [YamiboAccountTestURLProtocol.self]
    configuration.httpCookieStorage = HTTPCookieStorage.shared
    configuration.httpCookieAcceptPolicy = .always
    return URLSession(configuration: configuration)
}

private func httpResponse(
    url: URL,
    body: String,
    statusCode: Int = 200,
    headers: [String: String]? = nil
) -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
    )
}

private func loginFormHTML() -> String {
    """
    <html>
      <body class="pg_logging">
        <form id="loginform" method="post" action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;loginhash=Labc1&amp;mobile=2">
          <input type="hidden" name="formhash" value="form123" />
          <input type="hidden" name="referer" value="https://bbs.yamibo.com/./" />
          <input type="hidden" name="fastloginfield" value="username" />
          <input type="hidden" name="cookietime" value="2592000" />
          <select name="questionid">
            <option value="0">安全提问(未设置请忽略)</option>
            <option value="1">母亲的名字</option>
          </select>
        </form>
      </body>
    </html>
    """
}

private func profileHTML() -> String {
    """
    <html>
      <body>
        <div class="avatar_bg" style="background-image:url(uc_server/data/avatar/000/53/59/77_avatar_big.jpg?x)">
          <div class="avatar_m"><img src="uc_server/data/avatar/000/53/59/77_avatar_big.jpg?y" /></div>
          <div class="name">arkalin</div>
        </div>
        <ul class="user_box">
          <li><span>155</span>总积分</li>
          <li><span>29 点</span>积分</li>
          <li><span>377</span>对象</li>
        </ul>
        <ul class="myinfo_list">
          <li>UID<span>535977</span></li>
          <li>用户组<span><font>百合花蕾</font></span></li>
        </ul>
        <div class="btn_exit"><a href="member.php?mod=logging&amp;action=logout&amp;formhash=abc123">退出</a></div>
      </body>
    </html>
    """
}

private func clearSharedYamiboCookies() {
    for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("yamibo.com") {
        HTTPCookieStorage.shared.deleteCookie(cookie)
    }
}

private func storeYamiboCookies(_ headerFields: [String: String], for url: URL) {
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    for cookie in cookies {
        HTTPCookieStorage.shared.setCookie(cookie)
    }
}

private extension URLRequest {
    func httpBodyStreamData() -> Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
