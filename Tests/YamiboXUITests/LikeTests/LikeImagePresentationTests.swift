import Foundation
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

#if os(iOS)
final class LikeImagePresentationTests: XCTestCase {
    func testBrowserItemCarriesImageNoteAsCaption() throws {
        let item = makeImageLike(note: "这一页的构图很有意思")
        let browserItem = try XCTUnwrap(
            LikeImageBrowserItemFactory.make(
                item: item,
                title: "第 3 话",
                likeImageStore: LikeImageStore()
            )
        )

        XCTAssertEqual(browserItem.id, item.id)
        XCTAssertEqual(browserItem.title, "第 3 话")
        XCTAssertEqual(browserItem.caption, "这一页的构图很有意思")
    }

    func testBrowserItemOmitsMissingAndWhitespaceOnlyNotes() throws {
        let notes: [String?] = [nil, " \n\t "]

        for note in notes {
            let browserItem = try XCTUnwrap(
                LikeImageBrowserItemFactory.make(
                    item: makeImageLike(note: note),
                    title: "第 3 话",
                    likeImageStore: LikeImageStore()
                )
            )

            XCTAssertNil(browserItem.caption)
        }
    }

    func testBrowserItemRequiresASourceImageURL() {
        var item = makeImageLike(note: "笔记")
        item.sourceImageURL = nil

        XCTAssertNil(
            LikeImageBrowserItemFactory.make(
                item: item,
                title: "第 3 话",
                likeImageStore: LikeImageStore()
            )
        )
    }

    func testBrowserItemLoadsRetainedBytesForTheMappedItem() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("like-image-presentation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = LikeImageStore(baseDirectory: baseDirectory)
        let item = makeImageLike(note: "笔记")
        let expected = Data([0x01, 0x02, 0x03])
        try await store.save(expected, id: item.id, sourceURL: item.sourceImageURL)

        let browserItem = try XCTUnwrap(
            LikeImageBrowserItemFactory.make(
                item: item,
                title: "第 3 话",
                likeImageStore: store
            )
        )
        let provider = try XCTUnwrap(browserItem.localDataProvider)
        let loaded = await provider()

        XCTAssertEqual(loaded, expected)
    }

    private func makeImageLike(note: String?) -> LikeItem {
        LikeItem(
            id: "image-1",
            workKey: .mangaTitle(cleanBookName: "测试漫画"),
            kind: .image,
            sourceImageURL: URL(string: "https://img.example.com/page.jpg"),
            anchor: .mangaImage(
                MangaImageLikeAnchor(chapterTID: "100", pageLocalIndex: 2)
            ),
            note: note
        )
    }
}
#endif
