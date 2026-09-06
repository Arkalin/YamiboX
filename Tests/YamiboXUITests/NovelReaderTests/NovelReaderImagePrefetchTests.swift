import Foundation
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class NovelReaderImagePrefetchPlanTests: XCTestCase {
    func testSinglePageWindowOrderAndBoundaries() {
        XCTAssertEqual(names(plan(selected: 2)), ["2", "3", "4", "5", "1", "0"])
        XCTAssertEqual(names(plan(selected: 4)), ["4", "5", "6", "7", "3", "2", "1"])
        XCTAssertEqual(names(plan(selected: 0)), ["0", "1", "2", "3"])
        XCTAssertEqual(names(plan(selected: 8)), ["8", "7", "6", "5"])
    }

    func testSpreadsIncludeBothPagesAndTrailingSinglePage() {
        XCTAssertEqual(names(plan(selected: 3, spread: true)), ["2", "3", "4", "5", "6", "7", "8", "0", "1"])
        XCTAssertEqual(names(plan(selected: 8, spread: true)), ["8", "6", "7", "4", "5", "2", "3"])
    }

    func testEmptyDisabledAndTextOnlyPresentations() {
        var presentation = presentation(selected: 0)
        presentation.surfaces = []
        XCTAssertTrue(sources(presentation).isEmpty)
        presentation = self.presentation(selected: 0)
        presentation.committedSettings.loadsInlineImages = false
        XCTAssertTrue(sources(presentation).isEmpty)
        presentation.committedSettings.loadsInlineImages = true
        for index in presentation.surfaces.indices {
            presentation.surfaces[index].externalBlocks = []
        }
        XCTAssertTrue(sources(presentation).isEmpty)
    }

    func testDeduplicationAndPerDocumentRefererAndOfflineScope() {
        var presentation = presentation(selected: 2)
        presentation.surfaces[3].externalBlocks = presentation.surfaces[2].externalBlocks
        presentation.surfaces[4].documentView = 2
        presentation.surfaces[4].resolvedAuthorID = "77"
        let result = sources(presentation)
        XCTAssertEqual(names(result), ["2", "4", "5", "1", "0"])
        XCTAssertEqual(result[1].refererPageURL, YamiboRoute.threadByID(
            tid: "42", page: 2, authorID: "77", reverse: false
        ).url)
        XCTAssertTrue(result.allSatisfy { $0.offlineScope == YamiboImageOfflineScope(tid: "42") })
    }

    private func plan(selected: Int, spread: Bool = false) -> [YamiboImageSource] {
        sources(presentation(selected: selected), spread: spread)
    }

    private func sources(_ presentation: NovelReaderPresentation, spread: Bool = false) -> [YamiboImageSource] {
        NovelReaderImagePrefetchPlan.sources(
            presentation: presentation, usesTwoPageSpread: spread, threadID: "42", fallbackAuthorID: "12"
        )
    }

    private func names(_ sources: [YamiboImageSource]) -> [String] {
        sources.map { $0.url.lastPathComponent }
    }

    private func presentation(selected: Int) -> NovelReaderPresentation {
        let surfaces = (0..<9).map { index in
            NovelReaderSurface(
                identity: NovelReaderSurfaceIdentity(generation: 1, ordinal: index),
                presentationIndex: index,
                kind: .externalBlock,
                documentView: 1,
                chapterTitle: nil,
                presentationSize: CGSize(width: 320, height: 568),
                externalBlocks: [NovelReaderExternalBlock(url: prefetchSource(index).url, frame: nil)]
            )
        }
        let spreads = stride(from: 0, to: 9, by: 2).map { index in
            NovelReaderPresentationSpread(
                index: index / 2,
                leftSurfaceIndex: index,
                leftSurfaceIdentity: surfaces[index].identity,
                rightSurfaceIndex: index + 1 < 9 ? index + 1 : nil,
                rightSurfaceIdentity: index + 1 < 9 ? surfaces[index + 1].identity : nil,
                chapterTitle: nil
            )
        }
        return NovelReaderPresentation(
            generation: 1, revision: 1, surfaces: surfaces,
            selectedSurfaceIdentity: surfaces[selected].identity, spreads: spreads,
            committedSettings: NovelReaderAppearanceSettings(),
            readingState: NovelReaderReadingState(
                currentView: 1, maxView: 2, currentChapterTitle: nil,
                authorID: nil, currentSurfaceIntraProgress: 0
            ),
            retainedChapterCount: 1, filteredChapterCandidateCount: 0
        )
    }
}

@MainActor
final class NovelReaderImagePrefetchCoordinatorTests: XCTestCase {
    func testConcurrencyPriorityCachingAndDeduplication() async throws {
        let gate = PrefetchLoadGate()
        defer { gate.finishAll() }
        let coordinator = NovelReaderImagePrefetchCoordinator(
            isCached: { $0 == prefetchSource(0) }, load: { try await gate.load($0) }
        )
        defer { coordinator.cancel() }
        coordinator.update(sources: [0, 1, 1, 2, 3].map(prefetchSource))
        try await waitForPrefetch { gate.started == [1, 2] }
        XCTAssertEqual(gate.pending.count, 2)
        gate.finishFirst(1)
        try await waitForPrefetch { gate.started == [1, 2, 3] }
        XCTAssertEqual(gate.pending.count, 2)
    }

    func testWindowUpdatesRetainIntersectionAndCancelRemovedRequests() async throws {
        let gate = PrefetchLoadGate()
        defer { gate.finishAll() }
        let coordinator = NovelReaderImagePrefetchCoordinator(isCached: { _ in false }, load: { try await gate.load($0) })
        defer { coordinator.cancel() }
        coordinator.update(sources: [1, 2, 3].map(prefetchSource))
        try await waitForPrefetch { gate.started.count == 2 }
        coordinator.update(sources: [2, 4].map(prefetchSource))
        try await waitForPrefetch { gate.started.count == 3 && gate.cancelled == [1] }
        XCTAssertEqual(gate.started, [1, 2, 4])
        coordinator.cancel()
        try await waitForPrefetch { Set(gate.cancelled) == [1, 2, 4] }
    }

    func testStaleCompletionCannotRemoveNewRequestForSameURL() async throws {
        let gate = PrefetchLoadGate()
        defer { gate.finishAll() }
        let coordinator = NovelReaderImagePrefetchCoordinator(isCached: { _ in false }, load: { try await gate.load($0) })
        defer { coordinator.cancel() }
        coordinator.update(sources: [1, 2].map(prefetchSource))
        try await waitForPrefetch { gate.started.count == 2 }
        coordinator.cancel()
        coordinator.update(sources: [1, 2, 3].map(prefetchSource))
        try await waitForPrefetch { gate.started.count == 4 }
        gate.finishFirst(1)
        gate.finishFirst(2)
        // A stale completion would incorrectly free a slot and start image 3.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(gate.started, [1, 2, 1, 2])
        gate.finishFirst(1)
        try await waitForPrefetch { gate.started == [1, 2, 1, 2, 3] }
    }

    func testFailureDoesNotRetryUntilURLLeavesWindow() async throws {
        var calls = 0
        let coordinator = NovelReaderImagePrefetchCoordinator(isCached: { _ in false }, load: { _ in
            calls += 1
            throw YamiboError.invalidImageData
        })
        coordinator.update(sources: [prefetchSource(1)])
        try await waitForPrefetch { calls == 1 }
        coordinator.update(sources: [prefetchSource(1)])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        coordinator.update(sources: [])
        coordinator.update(sources: [prefetchSource(1)])
        try await waitForPrefetch { calls == 2 }
    }

    func testDeinitCancelsRequests() async throws {
        let gate = PrefetchLoadGate()
        defer { gate.finishAll() }
        var coordinator: NovelReaderImagePrefetchCoordinator? = NovelReaderImagePrefetchCoordinator(
            isCached: { _ in false }, load: { try await gate.load($0) }
        )
        coordinator?.update(sources: [prefetchSource(1)])
        try await waitForPrefetch { gate.started == [1] }
        coordinator = nil
        try await waitForPrefetch { gate.cancelled == [1] }
    }
}

private func prefetchSource(_ index: Int) -> YamiboImageSource {
    YamiboImageSource(url: URL(string: "https://images.example.com/\(index)")!)
}

@MainActor
private final class PrefetchLoadGate {
    var started: [Int] = []
    var cancelled: [Int] = []
    var pending: [(index: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load(_ source: YamiboImageSource) async throws {
        let index = Int(source.url.lastPathComponent)!
        started.append(index)
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending.append((index, $0)) }
        } onCancel: {
            Task { @MainActor in self.cancelled.append(index) }
        }
    }

    func finishFirst(_ index: Int) {
        guard let position = pending.firstIndex(where: { $0.index == index }) else { return }
        pending.remove(at: position).continuation.resume()
    }

    func finishAll() {
        let continuations = pending
        pending.removeAll()
        for item in continuations { item.continuation.resume() }
    }
}

@MainActor
private func waitForPrefetch(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for image prefetch")
}
