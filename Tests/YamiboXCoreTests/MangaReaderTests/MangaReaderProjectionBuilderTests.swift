import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Reader Projection Builder")
struct MangaReaderTestsReaderProjectionBuilder {
    @Test func builderDerivesAuthorFilteredProjectionFromThreadPage() throws {
        let identity = mangaProjectionIdentity(tid: "800", authorID: "42", view: 3)
        let page = mangaProjectionPage(
            tid: "800",
            title: "【作者】作品 第12话 - 中文百合漫画区 - 百合会",
            posts: [
                mangaProjectionPost(
                    postID: "9001",
                    authorUID: "42",
                    authorName: "作者42",
                    imageURLs: [
                        "/images/800-1.jpg",
                        "https://img.example.com/800-2.png",
                        "/images/800-1.jpg"
                    ]
                ),
                mangaProjectionPost(
                    postID: "9002",
                    authorUID: "42",
                    authorName: "作者42",
                    imageURLs: [
                        "https://img.example.com/800-3.png"
                    ]
                )
            ]
        )

        let projection = try MangaReaderProjectionBuilder.build(
            from: page,
            identity: identity,
            sourceFingerprint: "fingerprint-800"
        )

        #expect(projection.tid == "800")
        #expect(projection.ownerPostID == "9001")
        #expect(projection.ownerAuthorID == "42")
        #expect(projection.ownerAuthorName == "作者42")
        #expect(projection.chapterTitle == "【作者】作品 第12话")
        #expect(projection.sourceIdentity == identity)
        #expect(projection.sourceFingerprint == "fingerprint-800")
        #expect(projection.schemaVersion == MangaReaderProjection.schemaVersion)
        #expect(projection.parserVersion == MangaReaderProjection.parserVersion)
        #expect(projection.imageURLs.map(\.absoluteString) == [
            "https://bbs.yamibo.com/images/800-1.jpg",
            "https://img.example.com/800-2.png",
            "https://img.example.com/800-3.png"
        ])
    }

    @Test func builderRejectsMissingAuthorID() throws {
        let page = mangaProjectionPage(
            tid: "801",
            title: "第1话",
            posts: [mangaProjectionPost(postID: "9101", imageURLs: ["https://img.example.com/801.jpg"])]
        )

        #expect(throws: YamiboError.parsingFailed(context: "漫画作者范围")) {
            _ = try MangaReaderProjectionBuilder.build(
                from: page,
                identity: mangaProjectionIdentity(tid: "801", authorID: nil),
                sourceFingerprint: "fingerprint-801"
            )
        }
    }

    @Test func builderThrowsCurrentChapterFailureWhenNoImagesAreReadable() throws {
        let page = mangaProjectionPage(
            tid: "802",
            title: "空章节 第1话",
            posts: [mangaProjectionPost(postID: "9201", imageURLs: [])]
        )

        #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.current_page_not_manga_chapter"))) {
            _ = try MangaReaderProjectionBuilder.build(
                from: page,
                identity: mangaProjectionIdentity(tid: "802", authorID: "42"),
                sourceFingerprint: "fingerprint-802"
            )
        }
    }

    @Test func builderUsesRawTitleFallbacksAndCustomVersions() throws {
        let identity = mangaProjectionIdentity(tid: "803", authorID: "42")
        let page = mangaProjectionPage(
            tid: "803",
            title: "  ",
            posts: [
                mangaProjectionPost(
                    postID: "  ",
                    authorUID: "42",
                    authorName: "  ",
                    imageURLs: ["https://img.example.com/803.jpg"]
                )
            ]
        )

        let projection = try MangaReaderProjectionBuilder.build(
            from: page,
            identity: identity,
            sourceFingerprint: "fingerprint-803",
            schemaVersion: 99,
            parserVersion: 88
        )

        #expect(projection.ownerPostID == "803")
        #expect(projection.ownerAuthorID == "42")
        #expect(projection.ownerAuthorName == nil)
        #expect(projection.chapterTitle == "803")
        #expect(projection.schemaVersion == 99)
        #expect(projection.parserVersion == 88)
    }
}

private func mangaProjectionIdentity(
    tid: String,
    authorID: String?,
    view: Int = 1
) -> MangaReaderProjectionSourceIdentity {
    MangaReaderProjectionSourceIdentity(
        tid: tid,
        authorID: authorID,
        view: view
    )
}

private func mangaProjectionPage(
    tid: String,
    title: String,
    posts: [ForumThreadPost],
    currentPage: Int = 1
) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: title,
        posts: posts,
        pageNavigation: ForumPageNavigation(currentPage: currentPage, totalPages: currentPage)
    )
}

private func mangaProjectionPost(
    postID: String,
    authorUID: String = "42",
    authorName: String = "作者42",
    imageURLs: [String]
) -> ForumThreadPost {
    ForumThreadPost(
        postID: postID,
        author: BlogReaderUser(uid: authorUID, name: authorName),
        contentHTML: imageURLs.map { #"<img src="\#($0)" />"# }.joined(),
        contentText: "",
        images: imageURLs.map { ForumThreadPostImage(url: $0) }
    )
}
