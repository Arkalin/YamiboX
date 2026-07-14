import Foundation
import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MineHomeViewModelTests: XCTestCase {
    func testLoadRefreshesMatchingCachedProfileOncePerCredential() async throws {
        let fixture = try await makeMineHomeFixture(
            accountUID: "535977",
            cachedProfile: makeProfile(uid: "535977")
        )
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testLoadRefreshesMissingCachedProfileOnlyOncePerCredential() async throws {
        let fixture = try await makeMineHomeFixture()
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testManualRefreshStillRequestsProfileWhenCachedProfileExists() async throws {
        let fixture = try await makeMineHomeFixture(
            accountUID: "535977",
            cachedProfile: makeProfile(uid: "535977")
        )
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()
        await viewModel.refreshProfile()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testLoadRefreshesWhenCachedProfileUIDConflictsWithSessionUID() async throws {
        let fixture = try await makeMineHomeFixture(
            accountUID: "535977",
            cachedProfile: makeProfile(uid: "111111")
        )
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testAutomaticRefreshFailureKeepsCachedProfileWithoutPresentingError() async throws {
        let fixture = try await makeMineHomeFixture(
            accountUID: "535977",
            cachedProfile: makeProfile(uid: "535977")
        )
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { _ in
            requestCount += 1
            throw MineProfileRefreshTestError.missingHandler
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()

        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testManualRefreshFailurePresentsErrorWhenCachedProfileExists() async throws {
        let fixture = try await makeMineHomeFixture(
            accountUID: "535977",
            cachedProfile: makeProfile(uid: "535977")
        )
        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var shouldFail = false
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            if shouldFail {
                throw MineProfileRefreshTestError.missingHandler
            }
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.load()
        shouldFail = true
        await viewModel.refreshProfile()

        XCTAssertEqual(requestCount, 2)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
    }

    func testManualCheckInUsesSharedServiceWithoutForceAndShowsSkippedTodayMessage() async throws {
        let fixture = try await makeMineHomeFixture()
        let checkInService = RecordingCheckInService(result: .skippedToday)
        let viewModel = MineHomeViewModel(
            dependencies: fixture.appContext.accountDependencies,
            checkInService: checkInService
        )

        await viewModel.checkIn()

        let forces = await checkInService.snapshotForces()
        XCTAssertEqual(forces, [false])
        XCTAssertEqual(
            viewModel.checkInResultMessage,
            YamiboCheckInResult.alreadyCheckedInToday.message
        )
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isCheckingIn)
        XCTAssertTrue(viewModel.hasCheckedInToday)
    }

    func testManualCheckInAlreadyCheckedInShowsTodayMessage() async throws {
        let fixture = try await makeMineHomeFixture()
        let checkInService = RecordingCheckInService(result: .alreadyCheckedInToday)
        let viewModel = MineHomeViewModel(
            dependencies: fixture.appContext.accountDependencies,
            checkInService: checkInService
        )

        await viewModel.checkIn()

        let forces = await checkInService.snapshotForces()
        XCTAssertEqual(forces, [false])
        XCTAssertEqual(
            viewModel.checkInResultMessage,
            YamiboCheckInResult.alreadyCheckedInToday.message
        )
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasCheckedInToday)
    }

    func testManualCheckInSuccessRefreshesProfileWithoutOverwritingResult() async throws {
        let fixture = try await makeMineHomeFixture(accountUID: "535977")
        let checkInService = RecordingCheckInService(result: .success)
        nonisolated(unsafe) var requestCount = 0
        MineProfileRefreshTestURLProtocol.handler = { request in
            requestCount += 1
            return profileResponse(for: request, uid: "535977")
        }
        defer { MineProfileRefreshTestURLProtocol.handler = nil }

        let viewModel = MineHomeViewModel(
            dependencies: fixture.appContext.accountDependencies,
            checkInService: checkInService
        )
        viewModel.session = await fixture.appContext.sessionStore.load()

        await viewModel.checkIn()

        let forces = await checkInService.snapshotForces()
        XCTAssertEqual(forces, [false])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.profile?.uid, "535977")
        XCTAssertEqual(viewModel.checkInResultMessage, YamiboCheckInResult.success.message)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasCheckedInToday)
    }

    func testManualCheckInFailurePresentsError() async throws {
        let fixture = try await makeMineHomeFixture()
        let checkInService = RecordingCheckInService(result: .verificationFailed)
        let viewModel = MineHomeViewModel(
            dependencies: fixture.appContext.accountDependencies,
            checkInService: checkInService
        )

        await viewModel.checkIn()

        let forces = await checkInService.snapshotForces()
        XCTAssertEqual(forces, [false])
        XCTAssertNil(viewModel.checkInResultMessage)
        XCTAssertEqual(viewModel.errorMessage, YamiboCheckInResult.verificationFailed.message)
        XCTAssertFalse(viewModel.isCheckingIn)
        XCTAssertFalse(viewModel.hasCheckedInToday)
    }

    func testLoadShowsCheckedInTodayWhenLocalRecordExists() async throws {
        let fixture = try await makeMineHomeFixture(cachedProfile: makeProfile(uid: "535977"))
        let session = await fixture.appContext.sessionStore.load()
        await fixture.checkInStore.markCheckedIn(session: session)
        let viewModel = MineHomeViewModel(dependencies: fixture.appContext.accountDependencies)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasCheckedInToday)
    }

    func testManualCheckInDoesNotCallServiceWhenTodayAlreadyRecorded() async throws {
        let fixture = try await makeMineHomeFixture(cachedProfile: makeProfile(uid: "535977"))
        let session = await fixture.appContext.sessionStore.load()
        await fixture.checkInStore.markCheckedIn(session: session)
        let checkInService = RecordingCheckInService(result: .success)
        let viewModel = MineHomeViewModel(
            dependencies: fixture.appContext.accountDependencies,
            checkInService: checkInService
        )
        await viewModel.load()

        await viewModel.checkIn()

        let forces = await checkInService.snapshotForces()
        XCTAssertTrue(forces.isEmpty)
        XCTAssertEqual(
            viewModel.checkInResultMessage,
            YamiboCheckInResult.alreadyCheckedInToday.message
        )
        XCTAssertTrue(viewModel.hasCheckedInToday)
    }

}

private struct MineHomeViewModelFixture {
    let appContext: YamiboAppContext
    let checkInStore: YamiboCheckInStore
    let offlineCacheStore: any TestOfflineCacheStoring
    let directoryStore: MangaDirectoryStore
}

private func makeMineHomeFixture(
    accountUID: String? = nil,
    cachedProfile: YamiboProfile? = nil
) async throws -> MineHomeViewModelFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "mine-home-view-model")
    let sessionStore = try SessionStore(testSuiteName: defaultsSuiteName, key: "session")
    let profileStore = try YamiboProfileStore(testSuiteName: defaultsSuiteName, key: "profile")
    let checkInStore = YamiboCheckInStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        keyPrefix: "check-in"
    )
    let offlineCacheRoot = makeMineTemporaryDirectory()
    let database = try YamiboDatabase.openPool(rootDirectory: offlineCacheRoot)
    let offlineCacheStore = OfflineCacheStore(
        databasePool: database,
        baseDirectory: offlineCacheRoot.appendingPathComponent("offline-images", isDirectory: true)
    )
    let directoryStore = MangaDirectoryStore(databasePool: database)
    try await sessionStore.save(
        SessionState(
            cookie: "EeqY_2132_auth=token",
            userAgent: "Test-UA",
            isLoggedIn: true,
            accountUID: accountUID
        )
    )
    if let cachedProfile {
        try await profileStore.save(cachedProfile)
    }

    let appContext = YamiboAppContext(
        sessionStore: sessionStore,
        profileStore: profileStore,
        checkInStore: checkInStore,
        mangaDirectoryStore: directoryStore,
        offlineCacheStore: offlineCacheStore,
        session: makeProfileRefreshTestSession()
    )
    return MineHomeViewModelFixture(
        appContext: appContext,
        checkInStore: checkInStore,
        offlineCacheStore: offlineCacheStore,
        directoryStore: directoryStore
    )
}

private final class MineProfileRefreshTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: MineProfileRefreshTestError.missingHandler)
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum MineProfileRefreshTestError: Error {
    case missingHandler
}

private actor RecordingCheckInService: YamiboCheckInServicing {
    private let result: YamiboCheckInResult
    private var forces: [Bool] = []

    init(result: YamiboCheckInResult) {
        self.result = result
    }

    func checkInIfNeeded(force: Bool) async -> YamiboCheckInResult {
        forces.append(force)
        return result
    }

    func snapshotForces() -> [Bool] {
        forces
    }
}

private func makeProfileRefreshTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MineProfileRefreshTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func profileResponse(for request: URLRequest, uid: String) -> (Data, HTTPURLResponse) {
    XCTAssertEqual(request.url?.path, "/home.php")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Test-UA")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "EeqY_2132_auth=token")
    return httpResponse(url: request.url!, body: profileHTML(uid: uid))
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

private func makeProfile(uid: String) -> YamiboProfile {
    YamiboProfile(
        uid: uid,
        username: "arkalin",
        userGroup: "百合花蕾",
        points: 29,
        partner: 377,
        totalPoints: 155
    )
}

private func profileHTML(uid: String) -> String {
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
          <li>UID<span>\(uid)</span></li>
          <li>用户组<span><font>百合花蕾</font></span></li>
        </ul>
        <div class="btn_exit"><a href="member.php?mod=logging&amp;action=logout&amp;formhash=abc123">退出</a></div>
      </body>
    </html>
    """
}

private func makeMineTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

