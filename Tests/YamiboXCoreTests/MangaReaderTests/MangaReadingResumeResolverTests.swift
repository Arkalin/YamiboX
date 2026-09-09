import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Shared Reading Resume")
struct MangaReadingResumeResolverTests {
    @Test(arguments: MangaResumeScenario.cases)
    func resolvesThreadEntranceWithoutChangingProgress(_ scenario: MangaResumeScenario) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manga-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let progressStore = ReadingProgressStore(databasePool: try YamiboDatabase.openPool(rootDirectory: root))
        let directory = MangaDirectory(
            cleanBookName: "Book",
            strategy: .links,
            sourceKey: "source",
            chapters: [
                MangaChapter(tid: "100", rawTitle: "First", chapterNumber: 1, view: 3),
                MangaChapter(tid: "200", rawTitle: "Second", chapterNumber: 2, view: 1),
                MangaChapter(tid: "300", rawTitle: "Third", chapterNumber: 3, view: 2)
            ]
        )
        if scenario.hasThreadProgress {
            try await progressStore.saveMangaThread(MangaProgressReadingPosition(
                chapterThreadID: "200",
                chapterView: 6,
                chapterTitle: "Second",
                pageIndex: 9
            ), date: Date(timeIntervalSince1970: 100))
        }
        if scenario.hasDirectoryProgress {
            // The newer row also matches the original tid in a fuzzy lookup.
            try await progressStore.saveMangaTitle(
                cleanBookName: directory.cleanBookName,
                threadID: "200",
                chapterThreadID: "300",
                chapterView: 5,
                chapterTitle: "Third",
                pageIndex: 17,
                mangaID: directory.favoriteIdentity,
                date: Date(timeIntervalSince1970: 200)
            )
        }
        let originalRecords = await progressStore.loadAll()
        let directoryStore = ResumeDirectoryStore(state: scenario.directory, directory: directory)
        let resolver = MangaReadingResumeResolver(
            readingProgressStore: progressStore,
            mangaDirectoryStore: directoryStore
        )

        let resolution = await resolver.resolve(
            threadID: "200",
            title: "Book Second",
            isSmartModeEnabled: scenario.smart,
            startsFromBeginning: scenario.start,
            fallbackChapterView: 4
        )

        #expect(resolution == scenario.expected.resolution)
        #expect(await directoryStore.requestedTIDs == (scenario.smart ? ["200"] : []))
        #expect(await progressStore.loadAll() == originalRecords)
    }
}

struct MangaResumeScenario: Sendable, CustomStringConvertible {
    enum Directory: Sendable {
        case available, missing, empty, failure
    }

    enum Expected: Sendable {
        case threadFallback, threadProgress, threadStart, directoryProgress, directoryStart

        var resolution: MangaReadingResumeResolution {
            switch self {
            case .threadFallback:
                MangaReadingResumeResolution(chapterTID: "200", displayTitle: "Book Second", chapterView: 4, initialPage: 0, directoryName: nil)
            case .threadProgress:
                MangaReadingResumeResolution(chapterTID: "200", displayTitle: "Book Second", chapterView: 6, initialPage: 9, directoryName: nil)
            case .threadStart:
                MangaReadingResumeResolution(chapterTID: "200", displayTitle: "Book Second", chapterView: 1, initialPage: 0, directoryName: nil)
            case .directoryProgress:
                MangaReadingResumeResolution(chapterTID: "300", displayTitle: "Book", chapterView: 5, initialPage: 17, directoryName: "Book")
            case .directoryStart:
                MangaReadingResumeResolution(chapterTID: "100", displayTitle: "Book", chapterView: 3, initialPage: 0, directoryName: "Book")
            }
        }
    }

    let description: String
    let smart: Bool
    let start: Bool
    let directory: Directory
    let hasThreadProgress: Bool
    let hasDirectoryProgress: Bool
    let expected: Expected

    static let cases: [Self] = [
        .init(description: "mode off uses fallback view", smart: false, start: false, directory: .available,
              hasThreadProgress: false, hasDirectoryProgress: false, expected: .threadFallback),
        .init(description: "mode off ignores newer directory record", smart: false, start: false, directory: .available,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadProgress),
        .init(description: "mode off never borrows directory progress", smart: false, start: false, directory: .available,
              hasThreadProgress: false, hasDirectoryProgress: true, expected: .threadFallback),
        .init(description: "mode off starts original thread", smart: false, start: true, directory: .available,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadStart),
        .init(description: "unresolved directory uses fallback view", smart: true, start: false, directory: .missing,
              hasThreadProgress: false, hasDirectoryProgress: false, expected: .threadFallback),
        .init(description: "unresolved directory uses thread progress", smart: true, start: false, directory: .missing,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadProgress),
        .init(description: "empty directory uses thread progress", smart: true, start: false, directory: .empty,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadProgress),
        .init(description: "directory lookup failure uses thread progress", smart: true, start: false, directory: .failure,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadProgress),
        .init(description: "resolved directory uses directory progress", smart: true, start: false, directory: .available,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .directoryProgress),
        .init(description: "resolved directory without progress ignores thread progress", smart: true, start: false, directory: .available,
              hasThreadProgress: true, hasDirectoryProgress: false, expected: .directoryStart),
        .init(description: "resolved directory starts at first chapter actual view", smart: true, start: false, directory: .available,
              hasThreadProgress: false, hasDirectoryProgress: false, expected: .directoryStart),
        .init(description: "start ignores both progress records", smart: true, start: true, directory: .available,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .directoryStart),
        .init(description: "start without directory uses original thread view one", smart: true, start: true, directory: .missing,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadStart),
        .init(description: "start with empty directory uses original thread view one", smart: true, start: true, directory: .empty,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadStart),
        .init(description: "start with directory failure uses original thread view one", smart: true, start: true, directory: .failure,
              hasThreadProgress: true, hasDirectoryProgress: true, expected: .threadStart)
    ]
}

private actor ResumeDirectoryStore: MangaDirectoryPersisting {
    private let state: MangaResumeScenario.Directory
    private let directory: MangaDirectory
    private(set) var requestedTIDs: [String] = []

    init(state: MangaResumeScenario.Directory, directory: MangaDirectory) {
        self.state = state
        self.directory = directory
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        requestedTIDs.append(tid)
        switch state {
        case .available:
            return directory
        case .missing:
            return nil
        case .empty:
            var empty = directory
            empty.chapters = []
            return empty
        case .failure:
            throw ResumeDirectoryError.lookupFailed
        }
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        Issue.record("Thread resume should resolve its directory by thread ID")
        return nil
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        Issue.record("Resume resolution must not save directories")
    }

    func deleteDirectory(named name: String) async throws {
        Issue.record("Resume resolution must not delete directories")
    }

    func renameDirectory(from oldName: String, to newDirectory: MangaDirectory) async throws {
        Issue.record("Resume resolution must not rename directories")
        throw YamiboPersistenceError(context: "Read-only resume test store cannot rename directories")
    }
}

private enum ResumeDirectoryError: Error {
    case lookupFailed
}
