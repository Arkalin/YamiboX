import XCTest
@testable import YamiboXCore

final class NovelReaderSearchTests: XCTestCase {
    func testMatchesCaseAndWidthInsensitivelyWithoutOverlapping() async {
        let collector = NovelReaderSearchMatchCollector()

        await NovelReaderSearchEngine.search(
            snapshot: snapshot(text: "Alpha ＡＬＰＨＡ aaaa"),
            query: "alpha"
        ) { match in
            await collector.append(match)
        }

        let alphaMatches = await collector.values
        XCTAssertEqual(alphaMatches.map(\.matchedText), ["Alpha", "ＡＬＰＨＡ"])
        XCTAssertEqual(alphaMatches.map(\.startResumePoint.displayedTextOffset), [0, 6])

        await collector.removeAll()
        await NovelReaderSearchEngine.search(
            snapshot: snapshot(text: "aaaa"),
            query: "aa"
        ) { match in
            await collector.append(match)
        }

        let nonOverlappingMatches = await collector.values
        XCTAssertEqual(nonOverlappingMatches.map(\.startResumePoint.displayedTextOffset), [0, 2])
    }

    func testDoesNotMatchAcrossTextSegmentBoundaries() async {
        let collector = NovelReaderSearchMatchCollector()
        let snapshot = NovelReaderSearchSnapshot(
            generation: 7,
            view: 3,
            authorID: "42",
            readingMode: .paged,
            surfaceCount: 1,
            segments: [
                segment(text: "hello", identity: "first"),
                segment(text: "world", identity: "second")
            ]
        )

        await NovelReaderSearchEngine.search(snapshot: snapshot, query: "oworld") { match in
            await collector.append(match)
        }

        let matches = await collector.values
        XCTAssertTrue(matches.isEmpty)
    }

    func testBuildsContextPositionAndSemanticEndpoints() async throws {
        let collector = NovelReaderSearchMatchCollector()
        let text = "前文\n\n目标文字 后文"
        let chapterIdentity = NovelChapterIdentity(rawValue: "chapter-2")
        let textIdentity = NovelTextSegmentIdentity(rawValue: "segment-2")
        let snapshot = NovelReaderSearchSnapshot(
            generation: 9,
            view: 5,
            authorID: "84",
            readingMode: .paged,
            surfaceCount: 4,
            segments: [NovelReaderSearchSegment(
                text: text,
                chapterIdentity: chapterIdentity,
                textSegmentIdentity: textIdentity,
                fallbackChapterTitle: "第二章",
                surfaceRanges: [NovelReaderSearchSurfaceRange(
                    startOffset: 0,
                    endOffset: text.count,
                    surfaceOrdinal: 2,
                    chapterOrdinal: 1,
                    chapterTitle: "第二章"
                )]
            )]
        )

        await NovelReaderSearchEngine.search(snapshot: snapshot, query: "目标") { match in
            await collector.append(match)
        }

        let matches = await collector.values
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.chapterTitle, "第二章")
        XCTAssertEqual(match.positionLabel, "3")
        XCTAssertEqual(match.excerptPrefix, "前文 ")
        XCTAssertEqual(match.matchedText, "目标")
        XCTAssertEqual(match.excerptSuffix, "文字 后文")
        XCTAssertEqual(match.startResumePoint.view, 5)
        XCTAssertEqual(match.startResumePoint.chapterIdentity, chapterIdentity)
        XCTAssertEqual(match.startResumePoint.textSegmentIdentity, textIdentity)
        XCTAssertEqual(match.startResumePoint.displayedTextOffset, 4)
        XCTAssertEqual(match.endResumePoint.displayedTextOffset, 6)
        XCTAssertEqual(match.startResumePoint.authorID, "84")
    }

    func testVerticalModeUsesDocumentProgressPercent() async throws {
        let collector = NovelReaderSearchMatchCollector()
        let textIdentity = NovelTextSegmentIdentity(rawValue: "vertical")
        let snapshot = NovelReaderSearchSnapshot(
            generation: 2,
            view: 1,
            authorID: nil,
            readingMode: .vertical,
            surfaceCount: 5,
            segments: [NovelReaderSearchSegment(
                text: "01234target",
                chapterIdentity: nil,
                textSegmentIdentity: textIdentity,
                fallbackChapterTitle: nil,
                surfaceRanges: [
                    NovelReaderSearchSurfaceRange(
                        startOffset: 0,
                        endOffset: 5,
                        surfaceOrdinal: 0,
                        chapterOrdinal: 0,
                        chapterTitle: nil
                    ),
                    NovelReaderSearchSurfaceRange(
                        startOffset: 5,
                        endOffset: 11,
                        surfaceOrdinal: 4,
                        chapterOrdinal: 0,
                        chapterTitle: nil
                    )
                ]
            )]
        )

        await NovelReaderSearchEngine.search(snapshot: snapshot, query: "target") { match in
            await collector.append(match)
        }

        let matches = await collector.values
        XCTAssertEqual(try XCTUnwrap(matches.first).positionLabel, "100%")
    }

    private func snapshot(text: String) -> NovelReaderSearchSnapshot {
        NovelReaderSearchSnapshot(
            generation: 1,
            view: 1,
            authorID: nil,
            readingMode: .paged,
            surfaceCount: 1,
            segments: [segment(text: text, identity: "segment")]
        )
    }

    private func segment(text: String, identity: String) -> NovelReaderSearchSegment {
        NovelReaderSearchSegment(
            text: text,
            chapterIdentity: nil,
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: identity),
            fallbackChapterTitle: nil,
            surfaceRanges: [NovelReaderSearchSurfaceRange(
                startOffset: 0,
                endOffset: text.count,
                surfaceOrdinal: 0,
                chapterOrdinal: 0,
                chapterTitle: nil
            )]
        )
    }
}

private actor NovelReaderSearchMatchCollector {
    private var storage: [NovelReaderSearchMatch] = []

    var values: [NovelReaderSearchMatch] {
        storage
    }

    func append(_ match: NovelReaderSearchMatch) {
        storage.append(match)
    }

    func removeAll() {
        storage.removeAll()
    }
}
