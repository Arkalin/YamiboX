import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Page Projection")
struct MangaReaderTestsPageProjection {
    @Test func pageProjectionExpandsDocumentsWithStableIndexesAndSourceIdentity() throws {
        let first = try makeProjectionDocument(tid: "700", pageCount: 2)
        let second = try makeProjectionDocument(tid: "701", pageCount: 1)
        let window = try #require(MangaChapterWindow(
            directory: makeProjectionDirectory(tids: ["700", "701"]),
            documents: [first, second]
        ))

        let pages = MangaReaderPageProjection.projections(from: window)

        #expect(pages.map(\.id) == ["700#0", "700#1", "701#0"])
        #expect(pages.map(\.globalIndex) == [0, 1, 2])
        #expect(pages.map(\.localIndex) == [0, 1, 0])
        #expect(pages.map(\.chapterPageCount) == [2, 2, 1])
        #expect(pages[0].sourceIdentity == first.sourceIdentity)
        #expect(pages[2].sourceIdentity == second.sourceIdentity)
        #expect(pages[0].ownerPostID == "post-700")
    }

    @Test func pageProjectionResolvesPageIndexFromReadingPosition() throws {
        let document = try makeProjectionDocument(tid: "700", pageCount: 3)
        let window = MangaChapterWindow(
            directory: makeProjectionDirectory(tids: ["700"]),
            initialDocument: document,
            position: MangaReadingPosition(tid: "700", localIndex: 2)
        )
        let pages = MangaReaderPageProjection.projections(from: window)

        #expect(
            MangaReaderPageProjection.resolvedPageIndex(
                for: window.resolvedPosition,
                in: pages
            ) == 2
        )
    }

    @Test func pageProjectionResolvesPageIndexFromWindow() throws {
        let first = try makeProjectionDocument(tid: "700", pageCount: 2)
        let second = try makeProjectionDocument(tid: "701", pageCount: 2)
        let window = try #require(MangaChapterWindow(
            directory: makeProjectionDirectory(tids: ["700", "701"]),
            documents: [first, second],
            position: MangaReadingPosition(tid: "701", localIndex: 1)
        ))

        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 3)
    }
}

private func makeProjectionDirectory(tids: [String]) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .links,
        sourceKey: "测试漫画",
        chapters: tids.enumerated().map { index, tid in
            MangaChapter(
                tid: tid,
                rawTitle: "第\(index + 1)话",
                chapterNumber: Double(index + 1)
            )
        }
    )
}

private func makeProjectionDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    let imageURLs = try (0..<pageCount).map { index in
        try #require(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
    }
    return MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs
    )
}
