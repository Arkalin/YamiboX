import Foundation
import Testing
@testable import YamiboXCore

@Suite("Manga reader opening validation")
struct MangaReaderOpenValidatorTests {
    @Test func preservesChapterViewAndOfflineOwner() async throws {
        let validator = MangaReaderOpenValidator { request in
            #expect(request.threadID == "900")
            #expect(request.view == 4)
            #expect(request.offlineOwnerName == "Offline Book")
            return MangaReaderProjection(tid: "900", chapterTitle: "Chapter", imageURLs: [URL(string: "https://example.com/1.jpg")!])
        }
        let context = MangaLaunchContext(originalThreadID: "899", chapterTID: "900", displayTitle: "Book", source: .favorites, chapterView: 4, directoryName: "Offline Book")
        #expect(try await validator.validate(context).imageURLs.count == 1)
    }

    @Test func emptyProjectionIsRejected() async {
        let validator = MangaReaderOpenValidator { _ in
            MangaReaderProjection(tid: "900", chapterTitle: "Text", imageURLs: [])
        }
        await #expect(throws: MangaReaderOpenError.noReadableImages) {
            try await validator.validate(context())
        }
    }

    @Test func parserRejectionBecomesAnOpeningMessage() async {
        let validator = MangaReaderOpenValidator { _ in throw MangaReaderDataSupport.currentMangaChapterParsingFailure() }
        await #expect(throws: MangaReaderOpenError.noReadableImages) {
            try await validator.validate(context())
        }
    }

    @Test func authenticationFailuresAreNotMisreportedAsNonMangaContent() async {
        let validator = MangaReaderOpenValidator { _ in throw YamiboError.notAuthenticated }
        await #expect(throws: YamiboError.notAuthenticated) {
            try await validator.validate(context())
        }
    }

    private func context() -> MangaLaunchContext {
        MangaLaunchContext(originalThreadID: "900", chapterTID: "900", displayTitle: "Book", source: .forum)
    }
}
