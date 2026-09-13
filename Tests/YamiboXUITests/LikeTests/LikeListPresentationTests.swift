import SwiftUI
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class LikeListPresentationTests: XCTestCase {
    func testWorkNavigationTitleUsesCategoryOnIPadAndSelectionCountOnBothLayouts() {
        for filter in LikeWorkFilter.allCases {
            XCTAssertEqual(filter.navigationTitle(usesSidebar: true, selectedCount: nil), String(localized: filter.title))
            XCTAssertEqual(filter.navigationTitle(usesSidebar: false, selectedCount: nil), L10n.string("likes.section_title"))
            for usesSidebar in [false, true] {
                for count in [0, 3] {
                    XCTAssertEqual(filter.navigationTitle(usesSidebar: usesSidebar, selectedCount: count), L10n.string("likes.selected_count", count))
                }
            }
        }
    }

    func testWorkFiltersIntersectSearchWithoutChangingOrder() {
        let novel = LikeWorkKey.novel(threadID: "100")
        let manga = LikeWorkKey.mangaTitle(cleanBookName: "100")
        let works = [manga, novel].map { LikeWorkSummary(workKey: $0, itemCount: 2, lastLikedAt: .now) }
        let titles = [novel: "A Novel", manga: "A Manga"]
        XCTAssertEqual(LikeWorkFilter.all.applying(to: works, titles: titles, searchText: " a ").map(\.workKey), [manga, novel])
        XCTAssertEqual(LikeWorkFilter.novel.applying(to: works, titles: titles, searchText: "NOVEL").map(\.workKey), [novel])
        XCTAssertTrue(LikeWorkFilter.manga.applying(to: works, titles: titles, searchText: "Novel").isEmpty)
        XCTAssertEqual(LikeWorkFilter.manga.applying(to: works, titles: titles, searchText: " \n ").map(\.workKey), [manga])
    }

    func testItemFiltersIntersectExcerptsAndChaptersWithoutChangingOrder() {
        let text = makeItem(id: "text", kind: .text, chapter: "Stored chapter")
        let image = makeItem(id: "image", kind: .image)
        let items = [image, text]
        let titles = [image.id: "Cached chapter", text.id: "Do not use this stale title"]
        XCTAssertEqual(LikeContentFilter.all.applying(to: items, chapterTitles: titles, searchText: "chapter").map(\.id), [image.id, text.id])
        XCTAssertEqual(LikeContentFilter.text.applying(to: items, chapterTitles: titles, searchText: "EXCERPT").map(\.id), [text.id])
        XCTAssertTrue(LikeContentFilter.image.applying(to: items, chapterTitles: titles, searchText: "excerpt").isEmpty)
        XCTAssertTrue(LikeContentFilter.all.applying(to: items, chapterTitles: titles, searchText: "stale").isEmpty)
        XCTAssertEqual(LikeContentFilter.image.applying(to: items, chapterTitles: titles, searchText: " \n").map(\.id), [image.id])
    }

    @MainActor
    func testMetadataAndRowsFitNarrowAndWideLayoutsInBothColorSchemes() {
        for width: CGFloat in [288, 393, 1024] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    let metadata = UIHostingController(rootView: LikeItemMetadata(
                        chapterTitle: String(repeating: "Long chapter title ", count: 12), createdAt: .now
                    ).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
                    let measured = metadata.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertLessThanOrEqual(measured.width, width + 1)
                    XCTAssertGreaterThan(measured.height, 0)
                    XCTAssertLessThan(measured.height, 110)
                    let row = UIHostingController(rootView: LikeWorkRow(
                        title: String(repeating: "Long work title ", count: 10), coverURL: nil,
                        kind: .novel, itemCount: 12345, lastLikedAt: .now, isSelecting: false, isSelected: false
                    ).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
                    XCTAssertLessThanOrEqual(row.sizeThatFits(in: CGSize(width: width, height: 1000)).width, width + 1)
                }
            }
        }
    }

    @MainActor
    func testTextAndImageMetadataShareInsetsAndHandleMissingChapters() {
        let date = Date(timeIntervalSince1970: 1000)
        let noChapter = UIHostingController(rootView: LikeItemMetadata(chapterTitle: nil, createdAt: date))
        let withChapter = UIHostingController(rootView: LikeItemMetadata(chapterTitle: "Chapter", createdAt: date))
        let proposal = CGSize(width: 288, height: 1000)
        XCTAssertEqual(noChapter.sizeThatFits(in: proposal).height, withChapter.sizeThatFits(in: proposal).height, accuracy: 1)
        let large = UIHostingController(rootView: LikeItemMetadata(chapterTitle: "Chapter", createdAt: date).environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThan(large.sizeThatFits(in: proposal).height, withChapter.sizeThatFits(in: proposal).height)
    }

    private func makeItem(id: String, kind: LikeItemKind, chapter: String? = nil) -> LikeItem {
        LikeItem(id: id, workKey: .novel(threadID: "100"), kind: kind,
            excerptText: kind == .text ? "An excerpt" : nil,
            anchor: .novelImage(.init(chapterIdentity: .init(rawValue: "chapter"), imageSegmentIdentity: id, view: 1, resolvedAuthorID: nil)),
            chapterTitle: chapter)
    }
}
