import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class NovelReaderSearchCoordinatorTests: XCTestCase {
    func testBatchBoundaries() async {
        for count in [0, 1, 100, 101, 200, 201] {
            let coordinator = NovelReaderSearchCoordinator(
                snapshot: snapshot(text: String(repeating: "hit ", count: count))
            )

            coordinator.query = "hit"
            await waitForCompletion(coordinator)

            XCTAssertEqual(coordinator.matches.count, count, "count: \(count)")
            XCTAssertEqual(coordinator.visibleMatches.count, min(count, 100), "count: \(count)")
            XCTAssertEqual(coordinator.canLoadMore, count > 100, "count: \(count)")

            coordinator.loadMore()
            XCTAssertEqual(coordinator.visibleMatches.count, min(count, 200), "count: \(count)")
            XCTAssertEqual(coordinator.canLoadMore, count > 200, "count: \(count)")

            coordinator.loadMore()
            XCTAssertEqual(coordinator.visibleMatches.count, count, "count: \(count)")
            XCTAssertFalse(coordinator.canLoadMore, "count: \(count)")
        }
    }

    func testRevealsMatchesInBatchesOfOneHundred() async throws {
        let coordinator = NovelReaderSearchCoordinator(
            snapshot: snapshot(text: String(repeating: "hit ", count: 201))
        )

        coordinator.query = "hit"
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.matches.count, 201)
        XCTAssertEqual(coordinator.visibleMatches.count, 100)
        XCTAssertTrue(coordinator.canLoadMore)

        coordinator.loadMore()
        XCTAssertEqual(coordinator.visibleMatches.count, 200)
        XCTAssertTrue(coordinator.canLoadMore)

        coordinator.loadMore()
        XCTAssertEqual(coordinator.visibleMatches.count, 201)
        XCTAssertFalse(coordinator.canLoadMore)
    }

    func testChangingQueryCancelsAndDiscardsOldResults() async {
        let coordinator = NovelReaderSearchCoordinator(
            snapshot: snapshot(text: String(repeating: "alpha ", count: 500) + "beta")
        )

        coordinator.query = "alpha"
        await Task.yield()
        coordinator.query = "beta"
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.matches.count, 1)
        XCTAssertEqual(coordinator.matches.first?.matchedText, "beta")
    }

    func testPersistsDeduplicatedTenItemGlobalHistoryAndClearsIt() {
        XCTAssertTrue(YamiboAppStorageKey.resettable.contains(YamiboAppStorageKey.readerSearchHistory))

        let suiteName = "NovelReaderSearchCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "search-history"
        let coordinator = NovelReaderSearchCoordinator(
            snapshot: snapshot(text: ""),
            defaults: defaults,
            historyKey: key
        )

        for index in 0..<12 {
            coordinator.query = "query \(index)"
            coordinator.commitQueryToHistory()
        }
        coordinator.query = "ＱＵＥＲＹ 11"
        coordinator.commitQueryToHistory()

        XCTAssertEqual(coordinator.recentQueries.count, 10)
        XCTAssertEqual(coordinator.recentQueries.first, "ＱＵＥＲＹ 11")
        XCTAssertEqual(coordinator.recentQueries.last, "query 2")

        let restored = NovelReaderSearchCoordinator(
            snapshot: snapshot(text: ""),
            defaults: defaults,
            historyKey: key
        )
        XCTAssertEqual(restored.recentQueries, coordinator.recentQueries)

        restored.clearHistory()
        XCTAssertTrue(restored.recentQueries.isEmpty)
        XCTAssertNil(defaults.object(forKey: key))
    }

    private func waitForCompletion(_ coordinator: NovelReaderSearchCoordinator) async {
        for _ in 0..<10_000 {
            if coordinator.isSearchComplete { return }
            await Task.yield()
        }
        XCTFail("Search did not complete")
    }

    private func snapshot(text: String) -> NovelReaderSearchSnapshot {
        NovelReaderSearchSnapshot(
            generation: 1,
            view: 1,
            authorID: nil,
            readingMode: .paged,
            surfaceCount: 1,
            segments: [NovelReaderSearchSegment(
                text: text,
                chapterIdentity: nil,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "segment"),
                fallbackChapterTitle: "当前页",
                surfaceRanges: [NovelReaderSearchSurfaceRange(
                    startOffset: 0,
                    endOffset: text.count,
                    surfaceOrdinal: 0,
                    chapterOrdinal: 0,
                    chapterTitle: "当前页"
                )]
            )]
        )
    }
}

@MainActor
final class NovelReaderSearchSnapshotTests: XCTestCase {
    func testSnapshotUsesTransformedDisplayedTextFromOnlyCurrentProjection() throws {
        let runtime = NovelTextViewportRuntimeOwner()
        let first = try runtime.prepareTransaction(preparedInput: NovelTextLayout.prepareInput(
            document: NovelReaderProjection(
                threadID: "197",
                view: 1,
                maxView: 2,
                segments: [.text("旧网页", chapterTitle: "旧章节")]
            ),
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        ))
        XCTAssertTrue(runtime.commit(first))

        let current = try runtime.prepareTransaction(preparedInput: NovelTextLayout.prepareInput(
            document: NovelReaderProjection(
                threadID: "197",
                view: 2,
                maxView: 2,
                segments: [.text("繁體当前网页", chapterTitle: "当前章节")]
            ),
            settings: NovelReaderAppearanceSettings(readingMode: .paged, translationMode: .simplified),
            layout: NovelReaderLayout(width: 320, height: 480, readingMode: .paged)
        ))
        XCTAssertTrue(runtime.commit(current))

        let snapshot = try XCTUnwrap(runtime.currentSearchSnapshot())
        XCTAssertEqual(snapshot.view, 2)
        XCTAssertEqual(snapshot.generation, current.generation)
        XCTAssertEqual(snapshot.segments.map(\.text), ["繁体当前网页"])
        XCTAssertFalse(snapshot.segments.contains(where: { $0.text.contains("旧网页") }))
    }
}
