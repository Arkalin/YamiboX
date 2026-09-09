import Foundation
import Testing
@testable import YamiboXCore

@Suite
struct FavoriteRemoteSyncProbeTests {
    @Test func cachedPageSuppliesMetadataAndCoverWithoutAnotherFetch() async throws {
        let repository = SyncProbePageRepository(cached: syncProbePage())
        let covers = SyncProbeCoverRecorder()
        let payload = syncProbePayload(title: "Original title", authorID: "7")
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .novel(payload) },
            repository: repository,
            saveCover: { await covers.record(url: $0, target: $1) }
        )

        let result = try await probe.probe(syncProbeEntry)

        #expect(result.target == .novelThread(threadID: "900"))
        #expect(result.title == "Original title")
        #expect(result.authorID == "7")
        #expect(result.sourceGroup == .forumBoard(id: "49", label: "Forum"))
        #expect(result.coverURL?.absoluteString == "https://img.example.com/cover.jpg")
        #expect(result.contentUpdatedAt == FavoriteContentUpdateDateResolver.date(from: "2026-08-09 10:20"))
        #expect(result.contentUpdatedAt != nil)
        #expect(!result.sourceMetadataFetchFailed)
        #expect(await repository.fetchCount == 0)
        #expect(await covers.targets == [.novelThread(threadID: "900")])
    }

    @Test(arguments: [false, true])
    func mangaModePreservesChapterIdentityAndOriginalTitle(smartEnabled: Bool) async throws {
        let repository = SyncProbePageRepository(fetched: syncProbePage())
        let payload = syncProbePayload(title: "[Series] Chapter 02 [Translator]")
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in smartEnabled ? .manga(payload) : .mangaDirect(payload) },
            repository: repository,
            saveCover: { _, _ in }
        )

        let result = try await probe.probe(syncProbeEntry)

        #expect(result.target == .mangaThread(threadID: "900"))
        #expect(result.title == payload.title)
        #expect(await repository.fetchCount == 1)
    }

    @Test func fallbackUsesNormalThreadAndDefaultTitle() async throws {
        let repository = SyncProbePageRepository(cached: syncProbePage())
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .webFallback(syncProbeURL) },
            repository: repository,
            saveCover: { _, _ in }
        )

        let result = try await probe.probe(syncProbeEntry)

        #expect(result.target == .normalThread(threadID: "900"))
        #expect(result.title == L10n.string("forum.default_title"))
    }

    @Test func metadataAuthenticationFailureRetainsItsDiagnostics() async throws {
        let failure = LoadDiagnosticError.attaching(
            to: YamiboError.notAuthenticated,
            requestContext: syncProbeURL.absoluteString,
            httpStatus: 401
        )
        let repository = SyncProbePageRepository(failures: [failure])
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .thread(syncProbePayload()) },
            repository: repository,
            saveCover: { _, _ in Issue.record("A failed probe must not save a cover") }
        )

        do {
            _ = try await probe.probe(syncProbeEntry)
            Issue.record("Expected metadata failure instead of a degraded result")
        } catch {
            #expect(LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated)
            let details = LoadFailureDetails(error: error)
            #expect(details.httpStatus == 401)
            #expect(details.requestContext == syncProbeURL.absoluteString)
        }
        #expect(await repository.fetchCount == 1)
    }

    @Test func metadataCancellationEscapesUnchanged() async throws {
        let repository = SyncProbePageRepository(failures: [URLError(.cancelled)])
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .thread(syncProbePayload()) },
            repository: repository,
            saveCover: { _, _ in }
        )

        await #expect {
            _ = try await probe.probe(syncProbeEntry)
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }
        #expect(await repository.fetchCount == 1)
    }

    @Test func transientMetadataFailureRetriesOnlyAtEnginePolicyBoundary() async throws {
        let repository = SyncProbePageRepository(fetched: syncProbePage(), failures: [URLError(.timedOut)])
        let retries = SyncProbeRetryRecorder()
        let policy = FavoriteRemoteSyncRetryPolicy(wait: { await retries.recordWait($0) })
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .thread(syncProbePayload()) },
            repository: repository,
            saveCover: { _, _ in }
        )

        let result = try await policy.run { try await probe.probe(syncProbeEntry) }

        #expect(result.target == .normalThread(threadID: "900"))
        #expect(await repository.fetchCount == 2)
        #expect(await retries.waits == [1])
    }

    @Test func optionalCoverPersistenceFailureDoesNotDiscardResolvedMetadata() async throws {
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .thread(syncProbePayload()) },
            repository: SyncProbePageRepository(cached: syncProbePage()),
            saveCover: { _, _ in throw YamiboPersistenceError(context: "cover storage") }
        )

        let result = try await probe.probe(syncProbeEntry)

        #expect(result.forumID == "49")
        #expect(result.coverURL != nil)
    }

    @Test func coverPersistenceCancellationStillInterruptsProbe() async throws {
        let probe = FavoriteRemoteSyncProbe(
            resolve: { _ in .thread(syncProbePayload()) },
            repository: SyncProbePageRepository(cached: syncProbePage()),
            saveCover: { _, _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await probe.probe(syncProbeEntry)
        }
    }
}

@Suite
struct FavoriteRemoteSyncRetryPolicyTests {
    @Test func retriesTransientNetworkFailureWithBoundedBackoffAndOriginalError() async throws {
        let recorder = SyncProbeRetryRecorder()
        let policy = FavoriteRemoteSyncRetryPolicy(wait: { await recorder.recordWait($0) })
        let original = LoadDiagnosticError.attaching(to: URLError(.timedOut), requestContext: syncProbeURL.absoluteString)

        do {
            _ = try await policy.run { () -> Int in
                await recorder.recordAttempt()
                throw original
            }
            Issue.record("Expected the exhausted network failure")
        } catch {
            #expect((LoadDiagnosticError.classificationError(error) as? URLError)?.code == .timedOut)
            #expect(LoadFailureDetails(error: error).requestContext == syncProbeURL.absoluteString)
        }
        #expect(await recorder.attempts == 3)
        #expect(await recorder.waits == [1, 2])
    }

    @Test(arguments: [YamiboError.notAuthenticated, .floodControl, .securityVerificationRequired, .offline])
    func doesNotRetryRunFatalErrors(failure: YamiboError) async throws {
        let recorder = SyncProbeRetryRecorder()
        let policy = FavoriteRemoteSyncRetryPolicy(wait: { await recorder.recordWait($0) })
        let diagnostic = LoadDiagnosticError.attaching(to: failure, requestContext: syncProbeURL.absoluteString)

        await #expect {
            _ = try await policy.run { () -> Int in
                await recorder.recordAttempt()
                throw diagnostic
            }
        } throws: { error in
            LoadDiagnosticError.classificationError(error) as? YamiboError == failure
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.waits.isEmpty)
    }

    @Test(arguments: [URLError.Code.cancelled, .notConnectedToInternet, .secureConnectionFailed])
    func doesNotRetryCancellationOfflineOrPermanentTransportErrors(code: URLError.Code) async throws {
        let recorder = SyncProbeRetryRecorder()
        let policy = FavoriteRemoteSyncRetryPolicy(wait: { await recorder.recordWait($0) })

        await #expect {
            _ = try await policy.run { () -> Int in
                await recorder.recordAttempt()
                throw URLError(code)
            }
        } throws: { error in
            (error as? URLError)?.code == code
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.waits.isEmpty)
    }

    @Test func cancelledBackoffPreventsNextAttempt() async throws {
        let recorder = SyncProbeRetryRecorder()
        let policy = FavoriteRemoteSyncRetryPolicy(wait: { _ in throw CancellationError() })

        await #expect(throws: CancellationError.self) {
            _ = try await policy.run { () -> Int in
                await recorder.recordAttempt()
                throw URLError(.timedOut)
            }
        }
        #expect(await recorder.attempts == 1)
    }
}

private let syncProbeURL = YamiboRoute.threadByID(tid: "900", page: 1, authorID: nil, reverse: false).url
private let syncProbeEntry = YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-900", threadID: "900")

private func syncProbePayload(title: String = "Title", authorID: String? = nil) -> YamiboThreadRoutePayload {
    YamiboThreadRoutePayload(
        thread: ThreadIdentity(tid: "900"), title: title, authorID: authorID,
        canonicalURL: syncProbeURL, requestedURL: syncProbeURL
    )
}

private func syncProbePage() -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"), title: "Title",
        posts: [ForumThreadPost(
            postID: "p-900", floorText: "1#", author: BlogReaderUser(uid: "7", name: "Owner"),
            postedAtText: "2026-08-09 10:20", contentHTML: "", contentText: "",
            images: [ForumThreadPostImage(url: "https://img.example.com/cover.jpg")]
        )],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1),
        forumName: "Forum"
    )
}

private actor SyncProbePageRepository: ThreadCoverPageResolving {
    private let cached: ForumThreadPage?
    private let fetched: ForumThreadPage?
    private var failures: [any Error]
    private(set) var fetchCount = 0

    init(cached: ForumThreadPage? = nil, fetched: ForumThreadPage? = nil, failures: [any Error] = []) {
        self.cached = cached
        self.fetched = fetched
        self.failures = failures
    }

    func cachedThreadPage(thread: ThreadIdentity, title: String, authorID: String?, page: Int) async -> ForumThreadPage? {
        #expect(thread.tid == "900")
        #expect(authorID == nil)
        #expect(page == 1)
        return cached
    }

    func fetchThreadPage(thread: ThreadIdentity, title: String, authorID: String?, page: Int) async throws -> ForumThreadPage {
        #expect(thread.tid == "900")
        #expect(authorID == nil)
        #expect(page == 1)
        fetchCount += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return try #require(fetched)
    }
}

private actor SyncProbeCoverRecorder {
    private(set) var targets: [FavoriteItemTarget] = []

    func record(url: URL, target: FavoriteItemTarget) {
        #expect(url.absoluteString == "https://img.example.com/cover.jpg")
        targets.append(target)
    }
}

private actor SyncProbeRetryRecorder {
    private(set) var attempts = 0
    private(set) var waits: [Int] = []

    func recordAttempt() { attempts += 1 }
    func recordWait(_ retry: Int) { waits.append(retry) }
}
