import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite @MainActor
struct NovelDirectoryFailureTests {
    @Test func repeatedFailuresRetainOriginalCauseWithFreshEvents() async throws {
        let coordinator = makeCoordinator { _ in throw URLError(.timedOut) }
        await coordinator.previewChapterDirectoryWebView(2)
        let first = try #require(coordinator.chapterDirectory.failureEventID)
        #expect(coordinator.chapterDirectory.errorDetails?.causes.first?.code == URLError.timedOut.rawValue)
        await coordinator.previewChapterDirectoryWebView(2)
        #expect(coordinator.chapterDirectory.failureEventID != first)
        coordinator.clearChapterDirectoryFailure()
        #expect(coordinator.chapterDirectory.error == nil)
        #expect(coordinator.chapterDirectory.errorDetails == nil)
        #expect(coordinator.chapterDirectory.view == 2)
    }

    @Test func staleFailureCannotReplaceNewerDirectory() async throws {
        let request = SuspendedCatalog()
        let coordinator = makeCoordinator { view in
            if view == 2 { return try await request.load() }
            return []
        }
        let old = Task { await coordinator.previewChapterDirectoryWebView(2) }
        while request.continuation == nil { await Task.yield() }
        await coordinator.previewChapterDirectoryWebView(3)
        request.continuation?.resume(throwing: URLError(.timedOut))
        await old.value
        #expect(coordinator.chapterDirectory.view == 3)
        #expect(!coordinator.chapterDirectory.isLoading)
        #expect(coordinator.chapterDirectory.error == nil)
        #expect(coordinator.chapterDirectory.failureEventID == nil)
    }

    @Test func cancellationAndLeavingDirectoryDiscardLateResults() async {
        for leave in [false, true] {
            let request = SuspendedCatalog()
            let coordinator = makeCoordinator { _ in try await request.load() }
            let pending = Task { await coordinator.previewChapterDirectoryWebView(2) }
            while request.continuation == nil { await Task.yield() }
            if leave {
                coordinator.resetChapterDirectoryBrowsing()
            } else {
                pending.cancel()
            }
            request.continuation?.resume(returning: [])
            await pending.value
            #expect(!coordinator.chapterDirectory.isLoading)
            #expect(coordinator.chapterDirectory.error == nil)
            #expect(coordinator.chapterDirectory.failureEventID == nil)
            if leave { #expect(coordinator.chapterDirectory.view == nil) }
        }
    }

    private func makeCoordinator(
        preview: @escaping @MainActor @Sendable (Int) async throws -> [NovelChapterDirectoryEntry]
    ) -> NovelReaderNavigationCoordinator {
        NovelReaderNavigationCoordinator(reading: .init(
            maxView: { 3 }, visibleView: { 1 }, chapters: { [] }, surfaceCount: { 1 },
            currentChapterIndex: { nil }, stableResumePoint: { nil }, currentPageKey: { nil },
            previewChapterCatalog: preview, jumpToChapter: { _ in }, openChapterAnchor: { _ in nil },
            loadWebView: { _ in false }, restoreResumePoint: { _ in false }, scheduleProgressSync: {}
        ))
    }
}

@MainActor
private final class SuspendedCatalog {
    var continuation: CheckedContinuation<[NovelChapterDirectoryEntry], any Error>?

    func load() async throws -> [NovelChapterDirectoryEntry] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
