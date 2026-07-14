import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Chapter Window")
struct MangaReaderTestsChapterWindow {
    @Test func chapterWindowRejectsEmptyDocumentsAndDuplicateChapterIdentities() throws {
        let directory = makeDirectory(tids: ["700"])
        let first = try makeDocument(tid: "700", pageCount: 1)
        let duplicate = try makeDocument(tid: "700", pageCount: 2)

        #expect(MangaChapterWindow(directory: directory, documents: []) == nil)
        #expect(MangaChapterWindow(directory: directory, documents: [first, duplicate]) == nil)
    }

    @Test func chapterWindowCreatesDomainSnapshotAndClampsInitialPosition() throws {
        let directory = makeDirectory(tids: ["700"])
        let document = try makeDocument(tid: "700", pageCount: 2)

        let window = MangaChapterWindow(
            directory: directory,
            initialDocument: document,
            position: MangaReadingPosition(tid: "700", localIndex: 99)
        )

        let expectedPosition = MangaReadingPosition(tid: "700", localIndex: 1)
        #expect(window.directory == directory)
        #expect(window.documents == [document])
        #expect(window.position == expectedPosition)
        #expect(window.resolvedPosition == expectedPosition)
        #expect(window.snapshot == MangaChapterWindowSnapshot(
            documents: [document],
            resolvedPosition: expectedPosition
        ))
    }

    @Test func chapterWindowTrimsInitialDocumentsWithoutRemovingInitialPosition() throws {
        let directory = makeDirectory(tids: ["700", "701", "702"])
        let position = MangaReadingPosition(tid: "701", localIndex: 0)
        let window = try #require(MangaChapterWindow(
            directory: directory,
            documents: [
                makeDocument(tid: "700", pageCount: 1),
                makeDocument(tid: "701", pageCount: 1),
                makeDocument(tid: "702", pageCount: 1)
            ],
            position: position,
            maxLoadedDocuments: 2
        ))

        #expect(window.documents.map(\.tid) == ["701", "702"])
        #expect(window.position == position)
    }

    @Test func chapterWindowClearsUnknownOrEmptyPositions() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        let loadedDocument = try makeDocument(tid: "700", pageCount: 2)
        let emptyDocument = try makeDocument(tid: "701", pageCount: 0)
        var window = try #require(MangaChapterWindow(
            directory: directory,
            documents: [loadedDocument, emptyDocument]
        ))

        #expect(window.clampedPosition(MangaReadingPosition(tid: "999", localIndex: 0)) == nil)
        #expect(window.clampedPosition(MangaReadingPosition(tid: "701", localIndex: 0)) == nil)

        window.updatePosition(MangaReadingPosition(tid: "701", localIndex: 0))
        #expect(window.position == nil)
        #expect(window.snapshot.resolvedPosition == nil)
    }

    @Test func chapterWindowMovesReadingPositionByLoadedPageIndex() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        let first = try makeDocument(tid: "700", pageCount: 2)
        let second = try makeDocument(tid: "701", pageCount: 3)
        var window = try #require(MangaChapterWindow(
            directory: directory,
            documents: [first, second]
        ))

        let firstSnapshot = window.moveToLoadedPage(at: -10)
        #expect(firstSnapshot.resolvedPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        #expect(window.position == firstSnapshot.resolvedPosition)

        let lastSnapshot = window.moveToLoadedPage(at: 99)
        #expect(lastSnapshot.resolvedPosition == MangaReadingPosition(tid: "701", localIndex: 2))
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 4)
    }

    @Test func chapterWindowClearsPositionWhenMovingInsideWindowWithNoImages() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        let first = try makeDocument(tid: "700", pageCount: 0)
        let second = try makeDocument(tid: "701", pageCount: 0)
        var window = try #require(MangaChapterWindow(
            directory: directory,
            documents: [first, second],
            position: MangaReadingPosition(tid: "700", localIndex: 0)
        ))

        let snapshot = window.moveToLoadedPage(at: 0)

        #expect(snapshot.resolvedPosition == nil)
        #expect(window.position == nil)
    }

    @Test func chapterWindowInsertsAdjacentNextDocumentAndPreservesReadingPosition() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        let currentPosition = MangaReadingPosition(tid: "700", localIndex: 1)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 2),
            position: currentPosition
        )

        let result = window.insertAdjacentDocument(
            try makeDocument(tid: "701", pageCount: 3),
            preserving: currentPosition
        )

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected adjacent next insertion to change the Manga Chapter Window")
            return
        }
        #expect(pageIDs(for: window) == ["700#0", "700#1", "701#0", "701#1", "701#2"])
        #expect(snapshot.resolvedPosition == currentPosition)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 1)
    }

    @Test func chapterWindowInsertsAdjacentPreviousDocumentAndShiftsProjectedPageIndex() throws {
        let directory = makeDirectory(tids: ["699", "700"])
        let currentPosition = MangaReadingPosition(tid: "700", localIndex: 1)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 2),
            position: currentPosition
        )

        let result = window.insertAdjacentDocument(
            try makeDocument(tid: "699", pageCount: 3),
            preserving: currentPosition
        )

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected adjacent previous insertion to change the Manga Chapter Window")
            return
        }
        #expect(pageIDs(for: window) == ["699#0", "699#1", "699#2", "700#0", "700#1"])
        #expect(snapshot.resolvedPosition == currentPosition)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 4)
    }

    @Test func chapterWindowRejectsDuplicateUnknownAndNonAdjacentInsertionsWithoutChangingSnapshotPosition() throws {
        let directory = makeDirectory(tids: ["700", "701", "702"])
        let currentPosition = MangaReadingPosition(tid: "700", localIndex: 1)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 2),
            position: currentPosition
        )

        let duplicate = window.insertAdjacentDocument(
            try makeDocument(tid: "700", pageCount: 4),
            preserving: MangaReadingPosition(tid: "701", localIndex: 0)
        )
        expectUnchanged(duplicate, reason: .duplicateChapter, position: currentPosition)

        let unknown = window.insertAdjacentDocument(
            try makeDocument(tid: "999", pageCount: 1),
            preserving: MangaReadingPosition(tid: "701", localIndex: 0)
        )
        expectUnchanged(unknown, reason: .unknownChapter, position: currentPosition)

        let nonAdjacent = window.insertAdjacentDocument(
            try makeDocument(tid: "702", pageCount: 1),
            preserving: MangaReadingPosition(tid: "701", localIndex: 0)
        )
        expectUnchanged(nonAdjacent, reason: .notAdjacent, position: currentPosition)
        #expect(pageIDs(for: window) == ["700#0", "700#1"])
    }

    @Test func chapterWindowPreservesCurrentPositionWhenNoExplicitPreservingPositionIsProvided() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        let currentPosition = MangaReadingPosition(tid: "700", localIndex: 0)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 1),
            position: currentPosition
        )

        let result = window.insertAdjacentDocument(try makeDocument(tid: "701", pageCount: 1))

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected adjacent insertion to change the Manga Chapter Window")
            return
        }
        #expect(snapshot.resolvedPosition == currentPosition)
        #expect(window.position == currentPosition)
    }

    @Test func chapterWindowFallsBackToInsertedDocumentWhenInvalidPreservingPositionCannotBeResolved() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 1),
            position: MangaReadingPosition(tid: "700", localIndex: 0),
            maxLoadedDocuments: 1
        )

        let result = window.insertAdjacentDocument(
            try makeDocument(tid: "701", pageCount: 1),
            preserving: MangaReadingPosition(tid: "999", localIndex: 0)
        )

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected adjacent insertion to change the Manga Chapter Window")
            return
        }
        #expect(snapshot.documents.map(\.tid) == ["701"])
        #expect(snapshot.resolvedPosition == nil)
        #expect(window.documents.map(\.tid) == ["701"])
        #expect(window.position == nil)
    }

    @Test func chapterWindowAllowsEmptyAdjacentDocumentButCannotResolvePositionInsideIt() throws {
        let directory = makeDirectory(tids: ["700", "701"])
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 1),
            position: MangaReadingPosition(tid: "700", localIndex: 0)
        )

        let result = window.insertAdjacentDocument(
            try makeDocument(tid: "701", pageCount: 0),
            preserving: MangaReadingPosition(tid: "701", localIndex: 0)
        )

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected empty adjacent document insertion to change the Manga Chapter Window")
            return
        }
        #expect(snapshot.documents.map(\.tid) == ["700", "701"])
        #expect(snapshot.resolvedPosition == nil)
        #expect(pageIDs(for: window) == ["700#0"])
    }

    @Test func chapterWindowTrimsWithoutRemovingPreservedReadingPosition() throws {
        let directory = makeDirectory(tids: ["700", "701", "702"])
        let position = MangaReadingPosition(tid: "701", localIndex: 0)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 1),
            position: MangaReadingPosition(tid: "700", localIndex: 0),
            maxLoadedDocuments: 2
        )
        _ = window.insertAdjacentDocument(
            try makeDocument(tid: "701", pageCount: 1),
            preserving: position
        )

        let result = window.insertAdjacentDocument(
            try makeDocument(tid: "702", pageCount: 1),
            preserving: position
        )

        guard case let .changed(snapshot) = result else {
            Issue.record("Expected adjacent insertion with trimming to change the Manga Chapter Window")
            return
        }
        #expect(snapshot.documents.map(\.tid) == ["701", "702"])
        #expect(snapshot.resolvedPosition == position)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 0)
    }

    @Test func chapterWindowResetsToUnknownDocumentWithoutChangingDirectory() throws {
        let directory = makeDirectory(tids: ["700"])
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 2),
            position: MangaReadingPosition(tid: "700", localIndex: 0)
        )
        let unknownDocument = try makeDocument(tid: "999", pageCount: 2)

        let snapshot = window.reset(
            to: unknownDocument,
            position: MangaReadingPosition(tid: "999", localIndex: 1)
        )

        #expect(window.directory == directory)
        #expect(snapshot.documents == [unknownDocument])
        #expect(snapshot.resolvedPosition == MangaReadingPosition(tid: "999", localIndex: 1))
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 1)
    }

    @Test func chapterWindowUpdateDirectoryReordersDocumentsAndRetainsUnknownDocumentsStably() throws {
        let initialDirectory = makeDirectory(tids: ["700", "701"])
        let documents = try [
            makeDocument(tid: "700", pageCount: 1),
            makeDocument(tid: "900", pageCount: 1),
            makeDocument(tid: "701", pageCount: 1),
            makeDocument(tid: "901", pageCount: 1)
        ]
        let position = MangaReadingPosition(tid: "700", localIndex: 0)
        var window = try #require(MangaChapterWindow(
            directory: initialDirectory,
            documents: documents,
            position: position
        ))

        let snapshot = window.updateDirectory(
            makeDirectory(tids: ["701", "700"]),
            preserving: position
        )

        #expect(snapshot.documents.map(\.tid) == ["701", "700", "900", "901"])
        #expect(snapshot.resolvedPosition == position)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 1)
    }

    @Test func chapterWindowUpdateDirectoryUsesFirstDuplicateDirectoryEntry() throws {
        let initialDirectory = makeDirectory(tids: ["700", "701", "702"])
        let documents = try [
            makeDocument(tid: "700", pageCount: 1),
            makeDocument(tid: "701", pageCount: 1),
            makeDocument(tid: "702", pageCount: 1)
        ]
        let position = MangaReadingPosition(tid: "701", localIndex: 0)
        var window = try #require(MangaChapterWindow(
            directory: initialDirectory,
            documents: documents,
            position: position
        ))

        let snapshot = window.updateDirectory(
            makeDirectory(tids: ["702", "701", "702", "700"]),
            preserving: position
        )

        #expect(snapshot.documents.map(\.tid) == ["702", "701", "700"])
        #expect(snapshot.resolvedPosition == position)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 1)
    }

    @Test func chapterWindowRemovesLoadedDocumentsByTIDWithoutRemovingPreservedPosition() throws {
        let directory = makeDirectory(tids: ["699", "700", "701"])
        let position = MangaReadingPosition(tid: "700", localIndex: 0)
        var window = try #require(MangaChapterWindow(
            directory: directory,
            documents: [
                makeDocument(tid: "699", pageCount: 1),
                makeDocument(tid: "700", pageCount: 1),
                makeDocument(tid: "701", pageCount: 1)
            ],
            position: position
        ))

        let snapshot = window.removeLoadedDocuments(
            withTIDs: ["699", "701"],
            preserving: position
        )

        #expect(snapshot.documents.map(\.tid) == ["700"])
        #expect(snapshot.resolvedPosition == position)
        #expect(MangaReaderPageProjection.resolvedPageIndex(for: window) == 0)
    }

    @Test func chapterWindowFindsAdjacentChaptersOnlyAtDirectOffsetsAndLoadedRangeBoundaries() throws {
        let directory = makeDirectory(tids: ["699", "700", "701"])
        let position = MangaReadingPosition(tid: "700", localIndex: 0)
        var window = MangaChapterWindow(
            directory: directory,
            initialDocument: try makeDocument(tid: "700", pageCount: 1),
            position: position
        )

        #expect(window.adjacentChapter(from: position, delta: -1)?.tid == "699")
        #expect(window.adjacentChapter(from: position, delta: 1)?.tid == "701")
        #expect(window.adjacentChapter(from: position, delta: 0) == nil)
        #expect(window.adjacentChapter(from: position, delta: 2) == nil)
        #expect(window.adjacentChapterForLoadedRange(delta: -1)?.tid == "699")
        #expect(window.adjacentChapterForLoadedRange(delta: 1)?.tid == "701")

        _ = window.insertAdjacentDocument(
            try makeDocument(tid: "701", pageCount: 1),
            preserving: position
        )
        #expect(window.adjacentChapterForLoadedRange(delta: 1) == nil)

        let unknownBoundary = try #require(MangaChapterWindow(
            directory: directory,
            documents: [
                makeDocument(tid: "999", pageCount: 1),
                makeDocument(tid: "700", pageCount: 1)
            ]
        ))
        #expect(unknownBoundary.adjacentChapterForLoadedRange(delta: -1) == nil)
        #expect(unknownBoundary.adjacentChapterForLoadedRange(delta: 1)?.tid == "701")
    }
}

private func expectUnchanged(
    _ result: MangaChapterWindowMutationResult,
    reason expectedReason: MangaChapterWindowNoopReason,
    position expectedPosition: MangaReadingPosition?
) {
    guard case let .unchanged(snapshot, reason) = result else {
        Issue.record("Expected unchanged Manga Chapter Window")
        return
    }
    #expect(reason == expectedReason)
    #expect(snapshot.resolvedPosition == expectedPosition)
}

private func pageIDs(for window: MangaChapterWindow) -> [String] {
    MangaReaderPageProjection.projections(from: window).map(\.id)
}

private func makeDirectory(tids: [String]) -> MangaDirectory {
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

private func makeDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    let imageURLs = try (0..<pageCount).map { index in
        try #require(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
    }
    return MangaReaderProjection(
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs
    )
}
