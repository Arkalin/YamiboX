import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

#if os(iOS)
final class ForumThreadImageBrowserGalleryTests: XCTestCase {
    func testGalleryIncludesBrowsableCurrentPageImagesInRenderOrder() throws {
        let refererURL = try XCTUnwrap(URL(string: "https://www.yamibo.com/thread-100-1-1.html"))
        let page = ForumThreadPage(
            thread: ThreadIdentity(tid: "100"),
            title: "thread",
            posts: [
                post(
                    "1",
                    blocks: [
                        imageBlock(id: "top", url: "https://img.example.com/top.jpg", altText: "Top"),
                        imageBlock(id: "emoticon", url: "https://img.example.com/emoticon.gif", isEmoticon: true),
                        imageBlock(
                            id: "linked",
                            url: "https://img.example.com/linked.jpg",
                            linkURL: try XCTUnwrap(URL(string: "https://example.com/target"))
                        ),
                        ForumThreadContentBlock(id: "quote", kind: .quote([
                            imageBlock(id: "quote-image", url: "https://img.example.com/quote.jpg")
                        ])),
                        ForumThreadContentBlock(id: "collapse", kind: .collapse(title: "more", contentBlocks: [
                            imageBlock(id: "collapse-image", url: "https://img.example.com/collapse.jpg", altText: "Collapsed")
                        ])),
                        ForumThreadContentBlock(id: "locked", kind: .locked(cost: 10, contentBlocks: [
                            imageBlock(id: "locked-image", url: "https://img.example.com/locked.jpg")
                        ])),
                        ForumThreadContentBlock(id: "table", kind: .table(rows: [
                            [
                                ForumThreadTableCell(blocks: [
                                    imageBlock(id: "table-image", url: "https://img.example.com/table.jpg")
                                ])
                            ]
                        ]))
                    ]
                ),
                post(
                    "2",
                    blocks: [
                        imageBlock(id: "second", url: "https://img.example.com/second.jpg", altText: "Second")
                    ]
                )
            ]
        )

        let gallery = ForumThreadImageBrowserGallery(
            page: page,
            refererURL: refererURL,
            selectedBlockID: "collapse-image",
            defaultTitle: "Image"
        )

        XCTAssertEqual(
            gallery.items.map(\.id),
            ["top", "quote-image", "collapse-image", "locked-image", "table-image", "second"]
        )
        XCTAssertEqual(gallery.initialItemID, "collapse-image")
        XCTAssertEqual(gallery.items.map(\.title), ["Top", "Image", "Collapsed", "Image", "Image", "Second"])
        XCTAssertTrue(gallery.items.allSatisfy { $0.source.refererPageURL == refererURL })
        XCTAssertEqual(Set(gallery.items.map(\.id)).count, gallery.items.count)
    }

    func testGalleryFallsBackToFirstImageWhenSelectedBlockIsMissing() throws {
        let refererURL = try XCTUnwrap(URL(string: "https://www.yamibo.com/thread-100-1-1.html"))
        let page = ForumThreadPage(
            thread: ThreadIdentity(tid: "100"),
            title: "thread",
            posts: [
                post(
                    "1",
                    blocks: [
                        imageBlock(id: "first", url: "https://img.example.com/first.jpg"),
                        imageBlock(id: "second", url: "https://img.example.com/second.jpg")
                    ]
                )
            ]
        )

        let gallery = ForumThreadImageBrowserGallery(
            page: page,
            refererURL: refererURL,
            selectedBlockID: "missing",
            defaultTitle: "Image"
        )

        XCTAssertEqual(gallery.initialItemID, "first")
    }
}

private func post(_ postID: String, blocks: [ForumThreadContentBlock]) -> ForumThreadPost {
    ForumThreadPost(
        postID: postID,
        author: BlogReaderUser(uid: "42", name: "author"),
        contentHTML: "",
        contentText: "",
        contentBlocks: blocks
    )
}

private func imageBlock(
    id: String,
    url: String,
    altText: String? = nil,
    linkURL: URL? = nil,
    isEmoticon: Bool = false
) -> ForumThreadContentBlock {
    ForumThreadContentBlock(
        id: id,
        kind: .image(ForumThreadImageBlock(
            url: URL(string: url)!,
            altText: altText,
            linkURL: linkURL,
            isEmoticon: isEmoticon
        ))
    )
}
#endif
