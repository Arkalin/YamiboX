import Foundation
import Testing
import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Suite("Reader session dependencies")
final class ReaderSessionDependencyTests {
    private let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReaderSessionDependencyTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    @Test func lifecycleObservesLatestRouteAndLogicalCloseWithoutAppModel() throws {
        let recorder = SessionLifecycleRecorder()
        let initial = NovelLaunchContext(threadID: "910", threadTitle: "Novel", source: .favorites)
        let session = try makeSession(content: .novel(initial), lifecycle: recorder.lifecycle)
        let originalContentID = session.contentID
        #expect(session.resumeRoute == .novel(initial))
        #expect(recorder.events.isEmpty)

        session.activate()
        #expect(recorder.events.last?.route == .novel(initial))
        var latest = initial
        latest.initialView = 4
        session.updateResumeRoute(.novel(latest), contentID: originalContentID)
        #expect(session.resumeRoute == .novel(latest))
        #expect(recorder.events.last?.kind == "progress")
        #expect(recorder.events.last?.route == .novel(latest))

        session.present(.thread(ThreadNovelLaunchContext(thread: ThreadIdentity(tid: "910"), title: "Thread")))
        #expect(session.resumeRoute == nil)
        #expect(recorder.events.last?.kind == "activate")
        #expect(recorder.events.last?.previousRoute == .novel(latest))
        #expect(recorder.events.last?.route == nil)
        session.updateResumeRoute(.novel(initial), contentID: originalContentID)
        #expect(recorder.events.count == 3)

        session.deactivate()
        #expect(recorder.events.last?.kind == "deactivate")
        #expect(!session.isClosed)
        session.close()
        #expect(recorder.events.last?.kind == "close")
        #expect(recorder.events.last?.isClosed == true)
        #expect(recorder.events.allSatisfy { $0.sessionID == session.id })
        session.close()
        session.activate()
        session.present(.novel(initial))
        #expect(recorder.events.count == 5)
    }

    @Test func injectedValidatorPreparesMangaWithoutApplicationOwner() async throws {
        let recorder = SessionLifecycleRecorder()
        let initial = NovelLaunchContext(threadID: "920", threadTitle: "Novel", source: .forum)
        let session = try makeSession(content: .novel(initial), lifecycle: recorder.lifecycle)
        let manga = MangaLaunchContext(
            originalThreadID: "921", chapterTID: "922", displayTitle: "Manga", source: .history,
            chapterView: 3, initialPage: 7
        )
        await session.openMangaReader(manga)
        #expect(session.resumeRoute == .manga(manga))
        #expect(session.preparedMangaProjection?.tid == "922")
        #expect(session.preparedMangaProjection?.sourceIdentity.view == 3)
        #expect(recorder.events.last?.previousRoute == .novel(initial))
        #expect(recorder.events.last?.route == .manga(manga))
        #expect(!session.isSwitching)
        #expect(session.switchFailure == nil)
    }

    @Test func injectedValidationFailureKeepsCurrentContentAndRoute() async throws {
        let recorder = SessionLifecycleRecorder()
        let initial = NovelLaunchContext(threadID: "930", threadTitle: "Novel", source: .forum)
        let session = try makeSession(
            content: .novel(initial), lifecycle: recorder.lifecycle,
            validator: MangaReaderOpenValidator { _ in throw MangaReaderOpenError.noReadableImages }
        )
        let originalContentID = session.contentID
        let manga = MangaLaunchContext(originalThreadID: "931", chapterTID: "931", displayTitle: "Text", source: .forum)
        await session.openMangaReader(manga)
        #expect(session.contentID == originalContentID)
        #expect(session.resumeRoute == .novel(initial))
        #expect(session.preparedMangaProjection == nil)
        #expect(session.switchFailure?.summary == L10n.string("manga.open.no_readable_images"))
        #expect(!session.isSwitching)
        #expect(recorder.events.isEmpty)
    }

    @Test func deactivationRejectsLateValidationWithoutChangingContentGeneration() async throws {
        let recorder = SessionLifecycleRecorder()
        let gate = SessionValidationGate()
        let initial = NovelLaunchContext(threadID: "940", threadTitle: "Novel", source: .forum)
        let session = try makeSession(
            content: .novel(initial), lifecycle: recorder.lifecycle,
            validator: MangaReaderOpenValidator { request in
                await gate.wait()
                return sessionTestProjection(for: request)
            }
        )
        let originalContentID = session.contentID
        let manga = MangaLaunchContext(originalThreadID: "941", chapterTID: "941", displayTitle: "Manga", source: .forum)
        let opening = Task { await session.openMangaReader(manga) }
        await gate.waitUntilStarted()
        session.deactivate()
        await gate.release()
        await opening.value
        #expect(session.contentID == originalContentID)
        #expect(session.resumeRoute == .novel(initial))
        #expect(session.preparedMangaProjection == nil)
        #expect(session.switchFailure == nil)
        #expect(!session.isSwitching)
        #expect(recorder.events.map(\.kind) == ["deactivate"])
    }

    private func makeSession(
        content: ReaderSessionContent,
        lifecycle: ReaderSessionLifecycle,
        validator: MangaReaderOpenValidator? = nil
    ) throws -> ReaderSession {
        let suite = YamiboTestDefaults.suiteName(prefix: "reader-session-dependencies")
        let context = YamiboAppContext(
            sessionStore: try SessionStore(testSuiteName: suite, key: "session"),
            settingsStore: try SettingsStore(testSuiteName: suite, key: "settings"),
            readerResumeRouteStore: try ReaderResumeRouteStore(testSuiteName: suite, key: "resume"),
            readingProgressStore: try ReadingProgressStore(testSuiteName: suite, key: "progress"),
            grdbRootDirectory: rootDirectory,
            cachesRootDirectory: rootDirectory.appendingPathComponent("Caches")
        )
        return ReaderSession(
            content: content,
            dependencies: ReaderSessionDependencies(
                forum: context.forumDependencies,
                mangaReaderOpenValidator: validator ?? MangaReaderOpenValidator { sessionTestProjection(for: $0) }
            ),
            lifecycle: lifecycle
        )
    }
}

@MainActor
private final class SessionLifecycleRecorder {
    struct Event {
        let kind: String
        let sessionID: UUID
        let route: ReaderResumeRoute?
        let previousRoute: ReaderResumeRoute?
        let isClosed: Bool
    }

    private(set) var events: [Event] = []

    var lifecycle: ReaderSessionLifecycle {
        ReaderSessionLifecycle(
            didActivate: { [weak self] session, previous in self?.record("activate", session, previous: previous) },
            didUpdateResumeRoute: { [weak self] session, _ in self?.record("progress", session) },
            didDeactivate: { [weak self] session in self?.record("deactivate", session) },
            didClose: { [weak self] session in self?.record("close", session) }
        )
    }

    private func record(_ kind: String, _ session: ReaderSession, previous: ReaderResumeRoute? = nil) {
        events.append(Event(
            kind: kind, sessionID: session.id, route: session.resumeRoute,
            previousRoute: previous, isClosed: session.isClosed
        ))
    }
}

private actor SessionValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func sessionTestProjection(for request: MangaReaderProjectionRequest) -> MangaReaderProjection {
    MangaReaderProjection(
        tid: request.threadID, chapterTitle: "Manga",
        imageURLs: [URL(string: "https://example.com/page.jpg")!],
        sourceIdentity: MangaReaderProjectionSourceIdentity(tid: request.threadID, authorID: "42", view: request.view)
    )
}
