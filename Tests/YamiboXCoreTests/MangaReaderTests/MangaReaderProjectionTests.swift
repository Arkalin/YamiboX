import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Reader Projection")
struct MangaReaderTestsReaderProjection {
    @Test func readerProjectionStoresParsedImageContentWithoutHTML() throws {
        let imageURL = try #require(URL(string: "https://img.example.com/700-0.jpg"))

        let projection = MangaReaderProjection(
            tid: "700",
            ownerPostID: "900",
            chapterTitle: "第1话",
            imageURLs: [imageURL]
        )

        #expect(projection.tid == "700")
        #expect(projection.ownerPostID == "900")
        #expect(projection.chapterTitle == "第1话")
        #expect(projection.imageURLs == [imageURL])
        #expect(projection.sourceIdentity.tid == "700")
    }

    @Test func readerProjectionFallsBackToTIDWhenOwnerPostIDIsBlank() throws {
        let projection = MangaReaderProjection(
            tid: "701",
            ownerPostID: "  ",
            chapterTitle: "第2话",
            imageURLs: []
        )

        #expect(projection.ownerPostID == "701")
    }
}
