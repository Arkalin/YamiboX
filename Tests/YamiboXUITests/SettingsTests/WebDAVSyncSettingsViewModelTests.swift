import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class WebDAVSyncSettingsViewModelTests: XCTestCase {
    func testDownloadMismatchShowsErrorWithoutConfirmationAndPreservesSyncTimestamps() async throws {
        let suiteName = "webdav-settings-view-model-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let host = "settings-mismatch.example.com"
        let lastSyncedAt = Date(timeIntervalSince1970: 1_000)
        let lastRemoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let localUpdatedAt = Date(timeIntervalSince1970: 3_000)
        let settingsStore = WebDAVSyncSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            key: "webdav"
        )
        let sessionStore = SessionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            key: "session"
        )
        let downloadMismatchRootDirectory = makeWebDAVSettingsTemporaryDirectory(prefix: "download-mismatch")
        let appContext = YamiboAppContext(
            sessionStore: sessionStore,
            webDAVSyncSettingsStore: settingsStore,
            grdbRootDirectory: downloadMismatchRootDirectory,
            cachesRootDirectory: downloadMismatchRootDirectory,
            session: makeWebDAVSettingsTestSession()
        )

        try await settingsStore.save(WebDAVSyncSettings(
            baseURLString: "https://old.example.com",
            username: "old-user",
            password: "old-password",
            isAutoSyncEnabled: true,
            lastSyncedAt: lastSyncedAt,
            lastRemoteUpdatedAt: lastRemoteUpdatedAt,
            localUpdatedAt: localUpdatedAt
        ))
        try await sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true, accountUID: "local-uid"))

        let remotePayload = FavoriteLibraryWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 4_000),
            accountUID: "remote-uid",
            library: FavoriteLibraryDocument()
        )
        let encodedRemotePayload = try JSONEncoder().encode(remotePayload)
        WebDAVSettingsTestURLProtocol.setHandler(for: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            // Only the favorite-library dataset has remote data in this
            // fixture; every other participant's file (readingProgress,
            // appSettings, likeLibrary, ...) must 404 rather than receive
            // this payload verbatim, or their own version/shape checks throw
            // and mask the account-mismatch error this test is exercising.
            guard request.url?.lastPathComponent == "yamibox-favorite-library-v1.json" else {
                return (
                    Data(),
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
            return (
                encodedRemotePayload,
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        defer { WebDAVSettingsTestURLProtocol.removeHandler(for: host) }

        let viewModel = await WebDAVSyncSettingsViewModel(dependencies: appContext.webDAVSyncDependencies)
        await viewModel.load()
        await MainActor.run {
            viewModel.baseURLString = " https://\(host) "
            viewModel.username = " new-user "
            viewModel.password = "new-password"
            viewModel.isAutoSyncEnabled = false
            viewModel.direction = .download
        }

        let didSync = await viewModel.continueSync()

        XCTAssertFalse(didSync)
        let isShowingAccountMismatchConfirmation = await viewModel.isShowingAccountMismatchConfirmation
        XCTAssertFalse(isShowingAccountMismatchConfirmation)
        let errorMessage = await viewModel.errorMessage
        XCTAssertEqual(errorMessage, L10n.string("webdav.error.account_mismatch"))
        let savedSettings = await settingsStore.load()
        XCTAssertEqual(savedSettings.baseURLString, "https://\(host)")
        XCTAssertEqual(savedSettings.username, "new-user")
        XCTAssertEqual(savedSettings.password, "new-password")
        XCTAssertFalse(savedSettings.isAutoSyncEnabled)
        XCTAssertEqual(savedSettings.lastSyncedAt, lastSyncedAt)
        XCTAssertEqual(savedSettings.lastRemoteUpdatedAt, lastRemoteUpdatedAt)
        XCTAssertEqual(savedSettings.localUpdatedAt, localUpdatedAt)
    }

    func testUploadMismatchStillRequiresConfirmation() async throws {
        let suiteName = "webdav-settings-view-model-upload-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let host = "settings-upload-mismatch.example.com"
        let settingsStore = WebDAVSyncSettingsStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            key: "webdav"
        )
        let sessionStore = SessionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            key: "session"
        )
        let uploadMismatchRootDirectory = makeWebDAVSettingsTemporaryDirectory(prefix: "upload-mismatch")
        let appContext = YamiboAppContext(
            sessionStore: sessionStore,
            webDAVSyncSettingsStore: settingsStore,
            grdbRootDirectory: uploadMismatchRootDirectory,
            cachesRootDirectory: uploadMismatchRootDirectory,
            session: makeWebDAVSettingsTestSession()
        )

        try await settingsStore.save(WebDAVSyncSettings(
            baseURLString: "https://\(host)",
            username: "admin",
            password: "secret",
            isAutoSyncEnabled: true
        ))
        try await sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true, accountUID: "local-uid"))

        let remotePayload = FavoriteLibraryWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 4_000),
            accountUID: "remote-uid",
            library: FavoriteLibraryDocument()
        )
        let encodedRemotePayload = try JSONEncoder().encode(remotePayload)
        WebDAVSettingsTestURLProtocol.setHandler(for: host) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            // Only the favorite-library dataset has remote data in this
            // fixture; every other participant's file (readingProgress,
            // appSettings, likeLibrary, ...) must 404 rather than receive
            // this payload verbatim, or their own version/shape checks throw
            // and mask the account-mismatch error this test is exercising.
            guard request.url?.lastPathComponent == "yamibox-favorite-library-v1.json" else {
                return (
                    Data(),
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
            return (
                encodedRemotePayload,
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        defer { WebDAVSettingsTestURLProtocol.removeHandler(for: host) }

        let viewModel = await WebDAVSyncSettingsViewModel(dependencies: appContext.webDAVSyncDependencies)
        await viewModel.load()
        await MainActor.run {
            viewModel.direction = .upload
        }

        let didSync = await viewModel.continueSync()

        XCTAssertFalse(didSync)
        let isShowingAccountMismatchConfirmation = await viewModel.isShowingAccountMismatchConfirmation
        XCTAssertTrue(isShowingAccountMismatchConfirmation)
        let errorMessage = await viewModel.errorMessage
        XCTAssertNil(errorMessage)
    }
}

private final class WebDAVSettingsTestURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func setHandler(for host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
        }
    }

    static func removeHandler(for host: String) {
        _ = lock.withLock {
            handlers.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let host = request.url?.host,
            let handler = Self.lock.withLock({ Self.handlers[host] })
        else {
            client?.urlProtocol(self, didFailWithError: WebDAVSettingsTestError.missingHandler)
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

private enum WebDAVSettingsTestError: Error {
    case missingHandler
}

private func makeWebDAVSettingsTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebDAVSettingsTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeWebDAVSettingsTemporaryDirectory(prefix: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
