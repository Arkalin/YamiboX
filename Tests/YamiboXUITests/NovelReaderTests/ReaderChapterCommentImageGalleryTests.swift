import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class ReaderChapterCommentImageGalleryTests: XCTestCase {
    func testSelectedSecondImageOrderIdentityTitlesAndReferer() throws {
        let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "Chapter")
        let comment = ChapterComment(id: "first", source: .reply, authorName: "Reader", body: "Text", postID: "101", contentBlocks: [
            ForumThreadContentBlock(id: "text", kind: .text(.init(text: "Text"))),
            image("one", alt: " First "), image("smile", emoticon: true), image("two"),
            ForumThreadContentBlock(id: "quote", kind: .quote([image("quoted")]))
        ])
        let request = try XCTUnwrap(ReaderChapterCommentImageGallery.request(comment: comment, target: target, selectedBlockID: "two"))
        XCTAssertEqual(request.items.map(\.id), ["first:one", "first:two"])
        XCTAssertEqual(request.initialItemID, "first:two")
        XCTAssertEqual(request.items.map(\.title), ["First", "Chapter"])
        XCTAssertEqual(Set(request.items.map(\.source.url)).count, 1)
        XCTAssertTrue(request.items.allSatisfy { $0.source.refererPageURL == comment.originalPostURL(threadID: "42") })

        var other = comment
        other.id = "other"
        other.contentBlocks = [image("other-photo")]
        let otherRequest = try XCTUnwrap(ReaderChapterCommentImageGallery.request(comment: other, target: target, selectedBlockID: "other-photo"))
        XCTAssertEqual(otherRequest.items.map(\.id), ["other:other-photo"])
        XCTAssertTrue(Set(request.items.map(\.id)).isDisjoint(with: otherRequest.items.map(\.id)))
        for id in ["missing", "smile", "text", "quoted", "other-photo"] {
            XCTAssertNil(ReaderChapterCommentImageGallery.request(comment: comment, target: target, selectedBlockID: id))
        }
    }

    func testLegacyCommentCannotOpenImageBrowser() {
        let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "Chapter")
        let comment = ChapterComment(id: "legacy", source: .postComment, authorName: "Reader", body: "Text")
        XCTAssertNil(ReaderChapterCommentImageGallery.request(comment: comment, target: target, selectedBlockID: "one"))
    }

    func testMissingChapterTitleAndPostUseLocalizedTitleAndBaseReferer() throws {
        let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "  ")
        let comment = ChapterComment(id: "one", source: .postComment, authorName: "Reader", body: "", contentBlocks: [image("photo")])
        let item = try XCTUnwrap(ReaderChapterCommentImageGallery.request(comment: comment, target: target, selectedBlockID: "photo")?.items.first)
        XCTAssertEqual(item.title, L10n.string("forum.thread.image"))
        XCTAssertEqual(item.source.refererPageURL, YamiboDomain.baseURL)
    }

    private func image(_ id: String, alt: String? = nil, emoticon: Bool = false) -> ForumThreadContentBlock {
        ForumThreadContentBlock(id: id, kind: .image(.init(url: URL(string: "https://example.com/same.png")!, altText: alt, isEmoticon: emoticon)))
    }
}
