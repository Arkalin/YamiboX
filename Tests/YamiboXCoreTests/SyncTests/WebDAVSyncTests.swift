import Foundation
import Testing
@testable import YamiboXCore

private final class WebDAVTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: WebDAVTestError.missingHandler)
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

private enum WebDAVTestError: Error {
    case missingHandler
}

@Test func webDAVSyncRequiresStoredAccountUID() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-requires-account-uid")
    try await fixture.signInWithoutAccountUID()
    let service = fixture.makeService()

    await #expect(throws: YamiboError.accountUIDUnavailable) {
        _ = try await service.upload(using: fixture.settings)
    }
    await #expect(throws: YamiboError.accountUIDUnavailable) {
        _ = try await service.download(using: fixture.settings)
    }
}

@Test func webDAVServiceUploadWritesLocalFirstFavoriteLibraryAndReadingProgressPayloads() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-local-first-upload")
    try await fixture.signIn(accountUID: "100")

    let threadID = "940"
    var document = FavoriteLibraryDocument()
    let target = FavoriteItemTarget(kind: .novelThread, threadID: threadID)
    try document.upsertItem(
        FavoriteItem(
            target: target,
            title: "本地优先收藏",
            locations: [.category(document.defaultCategory.id)]
        )
    )
    try await fixture.localFavoriteLibraryStore.save(document)
    _ = try await fixture.readingProgressStore.saveNovel(
        NovelReadingPosition(threadID: threadID, view: 4, chapterTitle: "第四章")
    )

    var putPaths: [String] = []
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        if request.httpMethod == "GET" {
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            )
        }
        guard request.httpMethod == "PUT" || request.httpMethod == "MKCOL" else {
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        if request.httpMethod == "PUT" {
            let path = try #require(request.url?.path)
            putPaths.append(path)
            let body = try #require(request.webDAVBodyData())
            if path.hasSuffix("yamibox-favorite-library-v1.json") {
                let payload = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: body)
                #expect(payload.accountUID == "100")
                #expect(payload.library.items.map(\.id) == [target.id])
            } else if path.hasSuffix("yamibox-reading-progress-v1.json") {
                let payload = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: body)
                #expect(payload.records.map(\.id) == [target.id])
            }
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    _ = try await fixture.makeService().upload(using: fixture.settings, allowingAccountMismatch: true)

    #expect(!putPaths.contains { $0.hasSuffix("yamibo-sync-v1.json") })
    #expect(putPaths.contains { $0.hasSuffix("yamibox-favorite-library-v1.json") })
    #expect(putPaths.contains { $0.hasSuffix("yamibox-reading-progress-v1.json") })
}

@Test func webDAVServiceLocalFirstUploadWritesAppSettingsPayloadWithoutLegacyPayload() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-local-first-app-settings-upload")
    try await fixture.signIn(accountUID: "123")
    let appSettings = AppSettings(
        webBrowser: WebBrowserSettings(showsNavigationBar: false),
        system: SystemSettings(homePage: .favorites)
    )
    try await fixture.appSettingsStore.save(appSettings)

    var putPaths: [String] = []
    var uploadedAppSettings: AppSettingsWebDAVPayload?
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            let path = try #require(request.url?.path)
            putPaths.append(path)
            if path.hasSuffix("yamibox-app-settings-v1.json") {
                uploadedAppSettings = try JSONDecoder().decode(AppSettingsWebDAVPayload.self, from: try #require(request.webDAVBodyData()))
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    _ = try await fixture.makeService().upload(using: fixture.settings)

    #expect(!putPaths.contains { $0.hasSuffix("yamibo-sync-v1.json") })
    #expect(putPaths.contains { $0.hasSuffix("yamibox-favorite-library-v1.json") })
    #expect(putPaths.contains { $0.hasSuffix("yamibox-app-settings-v1.json") })
    #expect(uploadedAppSettings?.accountUID == "123")
    #expect(uploadedAppSettings?.appSettings == WebDAVSyncedAppSettings(settings: appSettings))
}

@Test func webDAVServiceLocalFirstDownloadAppliesAppSettingsPayloadWithoutLegacyPayload() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-local-first-app-settings-download")
    try await fixture.signIn(accountUID: "123")
    let localSettings = AppSettings(
        webBrowser: WebBrowserSettings(showsNavigationBar: true),
        system: SystemSettings(homePage: .forum)
    )
    let remoteSettings = WebDAVSyncedAppSettings(
        homePage: .favorites,
        webBrowser: WebBrowserSettings(showsNavigationBar: false)
    )
    let remotePayload = AppSettingsWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 2_000),
        accountUID: "123",
        appSettings: remoteSettings
    )
    try await fixture.appSettingsStore.save(localSettings)

    var getPaths: [String] = []
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        #expect(request.httpMethod == "GET")
        let path = try #require(request.url?.path)
        getPaths.append(path)
        if path.hasSuffix("yamibox-app-settings-v1.json") {
            return (
                try JSONEncoder().encode(remotePayload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    _ = try await fixture.makeService().download(using: fixture.settings)

    #expect(!getPaths.contains { $0.hasSuffix("yamibo-sync-v1.json") })
    let loadedSettings = await fixture.appSettingsStore.load()
    #expect(loadedSettings.system.homePage == .favorites)
    #expect(loadedSettings.webBrowser.showsNavigationBar == false)
}

@Test func webDAVAutomaticLocalFirstSyncUploadsWithoutLegacyPayload() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-local-first-auto-no-legacy")
    let localClock = Date(timeIntervalSince1970: 3_000)
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true,
        lastRemoteUpdatedAt: Date(timeIntervalSince1970: 1_000),
        localUpdatedAt: localClock
    ))
    try await fixture.signIn(accountUID: "123")

    var document = FavoriteLibraryDocument()
    try document.upsertItem(
        FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "965"),
            title: "自动同步收藏",
            locations: [.category(document.defaultCategory.id)]
        )
    )
    try await fixture.localFavoriteLibraryStore.save(document)

    var putPaths: [String] = []
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            putPaths.append(try #require(request.url?.path))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    // Favorite library upload is gated on dirty tracking now; mark it dirty the
    // way the real debounced-local-change path does before syncing.
    try await service.markLocalDataChanged()
    let result = try await service.synchronizeAutomatically()

    #expect(result == .uploaded)
    #expect(!putPaths.contains { $0.hasSuffix("yamibo-sync-v1.json") })
    #expect(putPaths.contains { $0.hasSuffix("yamibox-favorite-library-v1.json") })
    let updatedSettings = await fixture.settingsStore.load()
    #expect(updatedSettings.lastSyncedAt != nil)
    #expect(updatedSettings.lastRemoteUpdatedAt != nil)
}

@Test func webDAVAutomaticSyncSkipsNetworkRoundWithinMinimumInterval() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-min-interval-skip")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true,
        lastSyncedAt: .now,
        lastRemoteUpdatedAt: Date(timeIntervalSince1970: 1_000),
        localUpdatedAt: .now
    ))
    try await fixture.signIn(accountUID: "123")

    var requestCount = 0
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        requestCount += 1
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let result = try await fixture.makeService().synchronizeAutomatically()

    #expect(result == .skipped)
    #expect(requestCount == 0)
}

@Test func webDAVAutomaticSyncBypassesMinimumIntervalForForegroundAndBackgroundCheckpoints() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-min-interval-bypass")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true,
        lastSyncedAt: .now,
        lastRemoteUpdatedAt: .now,
        localUpdatedAt: .now
    ))
    try await fixture.signIn(accountUID: "123")

    var requestCount = 0
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        requestCount += 1
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let result = try await fixture.makeService().synchronizeAutomatically(bypassingMinimumInterval: true)

    // The bypassed round still reaches the network (unlike the interval-gated
    // round in the companion test); with nothing dirty and no remote payloads
    // it reports .skipped instead of stamping a phantom upload.
    #expect(result == .skipped)
    #expect(requestCount > 0)
}

@Test func webDAVAutomaticSyncAppliesNewerRemoteDataForCleanDatasetsWhenLocalTimestampIsAhead() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-clean-dataset-convergence")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")

    var localDocument = FavoriteLibraryDocument()
    let localTarget = FavoriteItemTarget(kind: .novelThread, threadID: "111")
    try localDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本地收藏",
        locations: [.category(localDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(localDocument)

    // Round 1 seeds fingerprints and per-dataset applied stamps through a
    // normal upload round against an empty remote.
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL", "PUT":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    try await service.markLocalDataChanged()
    let seededResult = try await service.synchronizeAutomatically()
    #expect(seededResult == .uploaded)
    let seededSettings = await fixture.settingsStore.load()
    let firstUploadUpdatedAt = try #require(seededSettings.localUpdatedAt)

    // Device B uploads a newer favorite library, and this device's
    // localUpdatedAt sits past it without any local change (the old
    // backgrounding-bump regression state).
    let remoteUpdatedAt = firstUploadUpdatedAt.addingTimeInterval(60)
    var bumpedSettings = seededSettings
    bumpedSettings.localUpdatedAt = remoteUpdatedAt.addingTimeInterval(60)
    try await fixture.settingsStore.save(bumpedSettings)

    var remoteDocument = FavoriteLibraryDocument()
    try remoteDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本地收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    try remoteDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "222"),
        title: "B设备新收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    let remoteFavoritePayload = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: remoteUpdatedAt,
        accountUID: "123",
        library: remoteDocument
    ))
    // App settings payload carrying the exact stamp this device already
    // absorbed in round 1: despite differing content it must not be applied.
    let staleRemoteAppSettingsPayload = try JSONEncoder().encode(AppSettingsWebDAVPayload(
        updatedAt: firstUploadUpdatedAt,
        accountUID: "123",
        appSettings: WebDAVSyncedAppSettings(
            homePage: .favorites,
            webBrowser: WebBrowserSettings(showsNavigationBar: false)
        )
    ))
    var putPathsAfterSeeding: [String] = []
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                return (remoteFavoritePayload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.hasSuffix("yamibox-app-settings-v1.json") == true {
                return (staleRemoteAppSettingsPayload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL", "PUT":
            putPathsAfterSeeding.append(request.url?.path ?? "")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }

    let localAppSettingsBeforeSync = await fixture.appSettingsStore.load()
    let result = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)

    #expect(result == .downloaded)
    #expect(putPathsAfterSeeding.isEmpty)
    let favorites = try await fixture.localFavoriteLibraryStore.load()
    #expect(favorites.items.contains { $0.target.threadID == "222" })
    let localAppSettingsAfterSync = await fixture.appSettingsStore.load()
    #expect(localAppSettingsAfterSync == localAppSettingsBeforeSync)
    let convergedSettings = await fixture.settingsStore.load()
    #expect(convergedSettings.localUpdatedAt == remoteUpdatedAt)
    #expect(convergedSettings.lastAppliedRemoteUpdatedAtByDatasetID["favoriteLibrary"] == remoteUpdatedAt)
    #expect(convergedSettings.dirtyDatasetIDs.isEmpty)

    // The applied content was fingerprinted right after applyRemote, so it is
    // not spuriously re-marked dirty (which would echo it back upward).
    try await service.markLocalDataChanged()
    let remarkedSettings = await fixture.settingsStore.load()
    #expect(remarkedSettings.dirtyDatasetIDs.isEmpty)
    #expect(remarkedSettings.localUpdatedAt == remoteUpdatedAt)
}

@Test func webDAVMarkLocalDataChangedDoesNotAdvanceLocalTimestampWhenNothingIsDirty() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-mark-clean-no-bump")
    try await fixture.settingsStore.save(WebDAVSyncSettings(isAutoSyncEnabled: true))
    let service = fixture.makeService()

    let seedDate = Date(timeIntervalSince1970: 1_000)
    try await service.markLocalDataChanged(at: seedDate)
    var seeded = await fixture.settingsStore.load()
    #expect(seeded.localUpdatedAt == seedDate)
    #expect(!seeded.dirtyDatasetIDs.isEmpty)

    // Simulate a completed sync round: dirty flags cleared, fingerprint
    // baselines kept.
    seeded.dirtyDatasetIDs = []
    try await fixture.settingsStore.save(seeded)

    try await service.markLocalDataChanged(at: Date(timeIntervalSince1970: 2_000))
    let unchanged = await fixture.settingsStore.load()
    #expect(unchanged.localUpdatedAt == seedDate)
    #expect(unchanged.dirtyDatasetIDs.isEmpty)

    var document = FavoriteLibraryDocument()
    try document.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "333"),
        title: "新收藏",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(document)

    let changeDate = Date(timeIntervalSince1970: 3_000)
    try await service.markLocalDataChanged(at: changeDate)
    let marked = await fixture.settingsStore.load()
    #expect(marked.localUpdatedAt == changeDate)
    #expect(marked.dirtyDatasetIDs.contains("favoriteLibrary"))
}

@Test func webDAVSyncKeepsMidUploadLocalChangesDirtyByFingerprintingAtExportTime() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-export-time-fingerprint")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")
    let participant = MutableContentWebDAVParticipant(content: "exported-content")
    let service = WebDAVSyncService(
        settingsStore: fixture.settingsStore,
        sessionStore: fixture.sessionStore,
        participants: [participant],
        client: WebDAVClient(session: makeWebDAVTestSession())
    )

    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            // A local edit lands while the PUT is in flight, after the export
            // snapshot was taken.
            participant.setContent("changed-mid-upload")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    try await service.markLocalDataChanged()
    let result = try await service.synchronizeAutomatically()
    #expect(result == .uploaded)

    let syncedSettings = await fixture.settingsStore.load()
    #expect(syncedSettings.lastSyncedFingerprintByDatasetID["mutableContent"] == "exported-content")

    // The mid-upload change must surface as dirty on the next mark pass
    // instead of being absorbed by an end-of-round fingerprint recompute.
    try await service.markLocalDataChanged()
    let remarked = await fixture.settingsStore.load()
    #expect(remarked.dirtyDatasetIDs.contains("mutableContent"))
}

@Test func webDAVAutomaticSyncLeavesSettingsUntouchedWhenNothingIsDirtyAndRemoteHasNothingNew() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-noop-round")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")

    // Echo server: GET returns whatever was last PUT to the same path.
    var storedBodies: [String: Data] = [:]
    var putCount = 0
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        let path = request.url?.path ?? ""
        switch request.httpMethod {
        case "GET":
            if let body = storedBodies[path] {
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            putCount += 1
            storedBodies[path] = request.webDAVBodyData() ?? Data()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    try await service.markLocalDataChanged()
    let uploadedResult = try await service.synchronizeAutomatically()
    #expect(uploadedResult == .uploaded)
    let settledSettings = await fixture.settingsStore.load()
    let putCountAfterUpload = putCount

    // Foreground checkpoint with nothing new anywhere: a phantom round must
    // not refresh any timestamp, or it would shadow later remote uploads.
    let result = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)

    #expect(result == .skipped)
    #expect(putCount == putCountAfterUpload)
    let after = await fixture.settingsStore.load()
    #expect(after == settledSettings)
}

@Test func webDAVLocalFirstManualSyncRequiresConfirmationForAccountMismatch() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-local-first-mismatch")
    try await fixture.signIn(accountUID: "local-uid")
    let remotePayload = FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 4_000),
        accountUID: "remote-uid",
        library: FavoriteLibraryDocument()
    )
    let encodedRemotePayload = try JSONEncoder().encode(remotePayload)
    var putCount = 0

    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                return (
                    encodedRemotePayload,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            putCount += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    await #expect(throws: WebDAVSyncError.accountMismatch(localUID: "local-uid", remoteUID: "remote-uid")) {
        _ = try await service.upload(using: fixture.settings)
    }
    #expect(putCount == 0)

    _ = try await service.upload(using: fixture.settings, allowingAccountMismatch: true)
    #expect(putCount == 3)
}

@Test func webDAVAutomaticSyncMergesDirtyLocalEditsWithNewerRemoteInsteadOfOverwriting() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-dirty-merge-download")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")

    // Local edit that has not been uploaded yet.
    var localDocument = FavoriteLibraryDocument()
    try localDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "111"),
        title: "本地未同步收藏",
        locations: [.category(localDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(localDocument)

    // Device B's newer remote library, which does not know the local edit.
    var remoteDocument = FavoriteLibraryDocument()
    try remoteDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "222"),
        title: "B设备收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    let remoteUpdatedAt = Date.now.addingTimeInterval(600)
    let remoteFavoritePayload = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: remoteUpdatedAt,
        accountUID: "123",
        library: remoteDocument
    ))

    var uploadedLibrary: FavoriteLibraryWebDAVPayload?
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                return (remoteFavoritePayload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                uploadedLibrary = try JSONDecoder().decode(
                    FavoriteLibraryWebDAVPayload.self,
                    from: try #require(request.webDAVBodyData())
                )
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    // Marks the favorite library dirty and stamps localUpdatedAt behind the
    // remote payload, putting this round in the remote-is-newer branch.
    try await service.markLocalDataChanged()

    let result = try await service.synchronizeAutomatically()

    #expect(result == .uploaded)
    // Both sides survive locally: the dirty dataset was merged, not replaced.
    let mergedLocal = try await fixture.localFavoriteLibraryStore.load()
    #expect(mergedLocal.items.contains { $0.target.threadID == "111" })
    #expect(mergedLocal.items.contains { $0.target.threadID == "222" })
    // The merged result was uploaded and sorts strictly after the absorbed
    // remote stamp, so other devices cannot skip it as already-applied.
    let uploaded = try #require(uploadedLibrary)
    #expect(uploaded.library.items.contains { $0.target.threadID == "111" })
    #expect(uploaded.library.items.contains { $0.target.threadID == "222" })
    #expect(uploaded.updatedAt > remoteUpdatedAt)
    let settled = await fixture.settingsStore.load()
    #expect(settled.dirtyDatasetIDs.isEmpty)
}

/// Clock-skew regression: device B's wall clock runs behind, so its upload
/// carries an *older* `updatedAt` than this device's bookkeeping, but a
/// *higher* revision. The date rule alone would discard it forever (direction
/// says local-is-ahead, the absorbed filter says already-applied); the
/// revision rule must download and absorb it.
@Test func webDAVAutomaticSyncDownloadsHigherRevisionRemoteDespiteOlderWallClock() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-revision-beats-older-clock")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")

    var localDocument = FavoriteLibraryDocument()
    let localTarget = FavoriteItemTarget(kind: .novelThread, threadID: "111")
    try localDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本机收藏",
        locations: [.category(localDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(localDocument)

    // Round 1: seed revision bookkeeping through a normal upload round
    // against an empty remote, and verify revision 1 was stamped into the
    // uploaded envelope.
    var uploadedFavoritePayload: FavoriteLibraryWebDAVPayload?
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                uploadedFavoritePayload = try JSONDecoder().decode(
                    FavoriteLibraryWebDAVPayload.self,
                    from: try #require(request.webDAVBodyData())
                )
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    try await service.markLocalDataChanged()
    let seededResult = try await service.synchronizeAutomatically()
    #expect(seededResult == .uploaded)
    let seededUpload = try #require(uploadedFavoritePayload)
    #expect(seededUpload.syncRevision == 1)
    let seededSettings = await fixture.settingsStore.load()
    let firstUploadUpdatedAt = try #require(seededSettings.localUpdatedAt)
    #expect(seededSettings.localRevisionByDatasetID["favoriteLibrary"] == 1)
    #expect(seededSettings.lastAppliedRemoteRevisionByDatasetID["favoriteLibrary"] == 1)

    // Device B (clock an hour behind) merged this device's upload, added
    // thread 222, and uploaded revision 5 with an older wall-clock stamp.
    let remoteUpdatedAt = firstUploadUpdatedAt.addingTimeInterval(-3600)
    var remoteDocument = FavoriteLibraryDocument()
    try remoteDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本机收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    try remoteDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "222"),
        title: "B设备新收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    let remoteFavoritePayload = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: remoteUpdatedAt,
        accountUID: "123",
        syncRevision: 5,
        library: remoteDocument
    ))
    var putPathsAfterSeeding: [String] = []
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                return (remoteFavoritePayload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL", "PUT":
            putPathsAfterSeeding.append(request.url?.path ?? "")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }

    let result = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)

    #expect(result == .downloaded)
    #expect(putPathsAfterSeeding.isEmpty)
    let favorites = try await fixture.localFavoriteLibraryStore.load()
    #expect(favorites.items.contains { $0.target.threadID == "222" })
    let convergedSettings = await fixture.settingsStore.load()
    #expect(convergedSettings.lastAppliedRemoteRevisionByDatasetID["favoriteLibrary"] == 5)
    #expect(convergedSettings.lastAppliedRemoteUpdatedAtByDatasetID["favoriteLibrary"] == remoteUpdatedAt)
    #expect(convergedSettings.dirtyDatasetIDs.isEmpty)

    // Refetching the same revision-5 payload is a no-op: absorbed by
    // revision, regardless of the wall-clock stamps involved.
    let repeated = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)
    #expect(repeated == .skipped)
    #expect(putPathsAfterSeeding.isEmpty)
    let settledSettings = await fixture.settingsStore.load()
    #expect(settledSettings == convergedSettings)
}

/// Mixed-version regression: a pre-revision peer keeps uploading payloads
/// without `syncRevision`. Those payloads must converge through the wall-clock
/// fallback exactly as before, and the next revision this device mints must
/// stay monotonic across the revision-less interlude.
@Test func webDAVAutomaticSyncFallsBackToWallClockForPreRevisionRemotePayloads() async throws {
    let fixture = try WebDAVSyncFixture(prefix: "webdav-pre-revision-fallback")
    try await fixture.settingsStore.save(WebDAVSyncSettings(
        baseURLString: "https://\(fixture.host)",
        username: "admin",
        password: "secret",
        isAutoSyncEnabled: true
    ))
    try await fixture.signIn(accountUID: "123")

    var localDocument = FavoriteLibraryDocument()
    let localTarget = FavoriteItemTarget(kind: .novelThread, threadID: "111")
    try localDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本机收藏",
        locations: [.category(localDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(localDocument)

    // Round 1: seed revision bookkeeping (revision 1) against an empty remote.
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL", "PUT":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }
    defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }

    let service = fixture.makeService()
    try await service.markLocalDataChanged()
    let seededResult = try await service.synchronizeAutomatically()
    #expect(seededResult == .uploaded)
    let seededSettings = await fixture.settingsStore.load()
    let firstUploadUpdatedAt = try #require(seededSettings.localUpdatedAt)

    // An old-version device uploads a newer (by date) payload with no
    // revision: thread 222 arrives, this device's copy of 111 is included.
    let legacyRemoteUpdatedAt = firstUploadUpdatedAt.addingTimeInterval(3600)
    var remoteDocument = FavoriteLibraryDocument()
    try remoteDocument.upsertItem(FavoriteItem(
        target: localTarget,
        title: "本机收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    try remoteDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "222"),
        title: "旧版设备收藏",
        locations: [.category(remoteDocument.defaultCategory.id)]
    ))
    let legacyRemotePayload = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: legacyRemoteUpdatedAt,
        accountUID: "123",
        library: remoteDocument
    ))
    var uploadedFavoritePayload: FavoriteLibraryWebDAVPayload?
    WebDAVTestURLProtocol.setHandler(for: fixture.host) { request in
        switch request.httpMethod {
        case "GET":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                return (legacyRemotePayload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        case "MKCOL":
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case "PUT":
            if request.url?.path.hasSuffix("yamibox-favorite-library-v1.json") == true {
                uploadedFavoritePayload = try JSONDecoder().decode(
                    FavoriteLibraryWebDAVPayload.self,
                    from: try #require(request.webDAVBodyData())
                )
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        default:
            Issue.record("Unexpected method \(request.httpMethod ?? "nil")")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
    }

    // Round 2 (clean): the revision-less payload lands through the date
    // fallback path, exactly as it did before revisions existed.
    let downloadResult = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)
    #expect(downloadResult == .downloaded)
    let downloadedFavorites = try await fixture.localFavoriteLibraryStore.load()
    #expect(downloadedFavorites.items.contains { $0.target.threadID == "222" })
    let downloadedSettings = await fixture.settingsStore.load()
    #expect(downloadedSettings.lastAppliedRemoteUpdatedAtByDatasetID["favoriteLibrary"] == legacyRemoteUpdatedAt)
    // The revision floor from round 1 is deliberately retained: it is never
    // compared against revision-less payloads and keeps future mints monotonic.
    #expect(downloadedSettings.lastAppliedRemoteRevisionByDatasetID["favoriteLibrary"] == 1)

    // Round 3 (dirty): a local edit merges with the revision-less remote and
    // the re-upload mints the next monotonic revision with a stamp past the
    // absorbed date (skew guard still in force on the fallback path).
    var editedDocument = try await fixture.localFavoriteLibraryStore.load()
    try editedDocument.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "333"),
        title: "本机新增收藏",
        locations: [.category(editedDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(editedDocument)
    try await service.markLocalDataChanged()

    let uploadResult = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)

    #expect(uploadResult == .uploaded)
    let uploaded = try #require(uploadedFavoritePayload)
    #expect(uploaded.syncRevision == 2)
    #expect(uploaded.updatedAt > legacyRemoteUpdatedAt)
    #expect(uploaded.library.items.contains { $0.target.threadID == "222" })
    #expect(uploaded.library.items.contains { $0.target.threadID == "333" })
    let mergedFavorites = try await fixture.localFavoriteLibraryStore.load()
    #expect(mergedFavorites.items.contains { $0.target.threadID == "222" })
    #expect(mergedFavorites.items.contains { $0.target.threadID == "333" })
    let settledSettings = await fixture.settingsStore.load()
    #expect(settledSettings.localRevisionByDatasetID["favoriteLibrary"] == 2)
    #expect(settledSettings.lastAppliedRemoteRevisionByDatasetID["favoriteLibrary"] == 2)
    #expect(settledSettings.dirtyDatasetIDs.isEmpty)
}

@Test func favoriteLibraryMergerToleratesDuplicateItemIDsFromMalformedPayloads() async throws {
    let document = try decodeDocumentWithDuplicateItems(olderTitle: "旧标题", newerTitle: "新标题")
    #expect(document.items.count == 2)

    let payload = FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 5_000),
        accountUID: "123",
        library: document
    )
    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: payload,
        remote: payload,
        updatedAt: Date(timeIntervalSince1970: 6_000)
    )

    let mergedItems = merged.library.items.filter { $0.target.threadID == "777" }
    #expect(mergedItems.count == 1)
    #expect(mergedItems.first?.title == "新标题")
}

@Test func favoriteLibraryDocumentInitializerDeduplicatesItemsByTargetID() async throws {
    let decoded = try decodeDocumentWithDuplicateItems(olderTitle: "旧标题", newerTitle: "新标题")
    #expect(decoded.items.count == 2)

    let rebuilt = FavoriteLibraryDocument(
        categories: decoded.categories,
        collections: decoded.collections,
        items: decoded.items,
        tags: decoded.tags
    )

    let rebuiltItems = rebuilt.items.filter { $0.target.threadID == "777" }
    #expect(rebuiltItems.count == 1)
    #expect(rebuiltItems.first?.title == "新标题")
}

/// Builds a document that (illegally) carries two items with the same target
/// id, as decoded from a payload written by a buggy or older peer — the
/// normalizing initializer forbids constructing this state in-process, so the
/// duplicate is spliced into the encoded JSON before decoding.
private func decodeDocumentWithDuplicateItems(
    olderTitle: String,
    newerTitle: String
) throws -> FavoriteLibraryDocument {
    var document = FavoriteLibraryDocument()
    try document.upsertItem(FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "777"),
        title: olderTitle,
        locations: [.category(document.defaultCategory.id)]
    ))
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any]
    )
    var items = try #require(object["items"] as? [[String: Any]])
    var duplicate = try #require(items.first)
    duplicate["title"] = newerTitle
    duplicate["updatedAt"] = try #require(duplicate["updatedAt"] as? Double) + 1_000
    items.append(duplicate)
    object["items"] = items
    return try JSONDecoder().decode(
        FavoriteLibraryDocument.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private struct WebDAVSyncFixture {
    let suiteName: String
    let host: String
    let settingsStore: WebDAVSyncSettingsStore
    let localFavoriteLibraryStore: FavoriteLibraryStore
    let readingProgressStore: ReadingProgressStore
    let sessionStore: SessionStore
    let appSettingsStore: SettingsStore
    let settings: WebDAVSyncSettings

    init(prefix: String) throws {
        suiteName = "\(prefix)-\(UUID().uuidString)"
        host = "\(prefix).example.com"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settingsStore = WebDAVSyncSettingsStore(defaults: try makeWebDAVDefaults(suiteName: suiteName), key: "webdav")
        localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try makeWebDAVDefaults(suiteName: suiteName),
            key: "local-favorites"
        )
        readingProgressStore = ReadingProgressStore(
            defaults: try makeWebDAVDefaults(suiteName: suiteName),
            key: "reading-progress"
        )
        sessionStore = SessionStore(defaults: try makeWebDAVDefaults(suiteName: suiteName), key: "session")
        appSettingsStore = SettingsStore(defaults: try makeWebDAVDefaults(suiteName: suiteName), key: "settings")
        settings = WebDAVSyncSettings(
            baseURLString: "https://\(host)",
            username: "admin",
            password: "secret"
        )
    }

    func signIn(accountUID: String) async throws {
        try await sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true, accountUID: accountUID))
    }

    func signInWithoutAccountUID() async throws {
        try await sessionStore.save(SessionState(cookie: "sid=local", isLoggedIn: true))
    }

    func makeService() -> WebDAVSyncService {
        WebDAVSyncService(
            settingsStore: settingsStore,
            sessionStore: sessionStore,
            participants: [
                FavoriteLibraryWebDAVParticipant(store: localFavoriteLibraryStore),
                ReadingProgressWebDAVParticipant(store: readingProgressStore),
                AppSettingsWebDAVParticipant(store: appSettingsStore),
            ],
            client: WebDAVClient(session: makeWebDAVTestSession())
        )
    }
}

/// Dirty-tracked participant whose content the test (or the fake server's PUT
/// handler) can mutate mid-round, with the raw content doubling as the
/// fingerprint.
private final class MutableContentWebDAVParticipant: WebDAVSyncParticipant, @unchecked Sendable {
    struct Payload: Codable {
        var updatedAt: Date
        var content: String
    }

    let datasetID = "mutableContent"
    let remoteFileName = "yamibox-mutable-content-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let lock = NSLock()
    private var content: String

    init(content: String) {
        self.content = content
    }

    var currentContent: String {
        lock.withLock { content }
    }

    func setContent(_ newValue: String) {
        lock.withLock { content = newValue }
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        WebDAVRemotePayloadInfo(updatedAt: try JSONDecoder().decode(Payload.self, from: data).updatedAt)
    }

    func mergeAndExport(remoteData _: Data?, updatedAt: Date, accountUID _: String) async throws -> Data {
        try JSONEncoder().encode(Payload(updatedAt: updatedAt, content: currentContent))
    }

    func applyRemote(_ data: Data) async throws {
        setContent(try JSONDecoder().decode(Payload.self, from: data).content)
    }

    func localFingerprint() async -> String? {
        currentContent
    }
}

private func makeWebDAVTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WebDAVTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeWebDAVDefaults(suiteName: String) throws -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw WebDAVTestError.missingHandler
    }
    return defaults
}

private extension URLRequest {
    func webDAVBodyData() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else { return nil }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while httpBodyStream.hasBytesAvailable {
            let readCount = httpBodyStream.read(buffer, maxLength: bufferSize)
            guard readCount > 0 else { break }
            data.append(buffer, count: readCount)
        }
        return data
    }
}
