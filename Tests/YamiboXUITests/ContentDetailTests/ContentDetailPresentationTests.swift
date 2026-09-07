import SwiftUI
import Testing
import XCTest
import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor @Suite("Detail directory presentation")
struct ContentDetailPresentationTests {
    @Test func layoutsDefaultToListAndRememberIndependentPreferences() throws {
        let defaults = try YamiboTestDefaults.make(suiteName: YamiboTestDefaults.suiteName(prefix: "detail-layout"))
        let novelKey = YamiboAppStorageKey.novelDetailChapterLayout
        let mangaKey = YamiboAppStorageKey.mangaDetailChapterLayout
        #expect(ChapterDirectoryLayout(storedValue: defaults.string(forKey: novelKey) ?? "") == .list)
        #expect(ChapterDirectoryLayout(storedValue: defaults.string(forKey: mangaKey) ?? "") == .list)
        defaults.set(ChapterDirectoryLayout.grid.rawValue, forKey: novelKey)
        #expect(ChapterDirectoryLayout(storedValue: defaults.string(forKey: novelKey) ?? "") == .grid)
        #expect(ChapterDirectoryLayout(storedValue: defaults.string(forKey: mangaKey) ?? "") == .list)
        defaults.set(ChapterDirectoryLayout.grid.rawValue, forKey: mangaKey)
        defaults.set(ChapterDirectoryLayout.list.rawValue, forKey: novelKey)
        #expect(defaults.string(forKey: mangaKey) == ChapterDirectoryLayout.grid.rawValue)
        #expect(ChapterDirectoryLayout(storedValue: "unknown") == .list)
        #expect(YamiboAppStorageKey.resettable.contains(novelKey))
        #expect(YamiboAppStorageKey.resettable.contains(mangaKey))
    }

    @Test(arguments: ["楼主", "123#", "2楼"])
    func novelNumbersRetainRealFloorLabels(floor: String) {
        let chapter = NovelChapterSummary(id: "page|post", title: "Chapter", view: 2, floorText: floor)
        let item = ChapterDirectoryItem.novel(chapter, indexInPage: 0)
        #expect(item.id == chapter.id)
        #expect(item.number == floor)
        #expect(item.numberAccessibilityLabel == floor)
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func missingFloorUsesExplicitPageLocalOrdinal(floor: String?) {
        let chapter = NovelChapterSummary(id: "page|post", title: "Chapter", view: 12, floorText: floor, isCurrentRead: true)
        let item = ChapterDirectoryItem.novel(chapter, indexInPage: 3)
        #expect(item.number == "4")
        #expect(item.numberAccessibilityLabel == L10n.string("forum.detail.page_item", 4))
        #expect(item.isCurrentRead)
        #expect(item.accessibilityValue.contains(L10n.string("forum.detail.current_read")))
    }

    @Test(arguments: [
        ("第1话", 1.0, "1"), ("第12话", 12.2, "12-2"),
        ("番外", 0.0, "SP"), ("特别篇", 0.0, "Ex"), ("最终话", 99.0, "终"), ("未编号", 0.0, "-")
    ])
    func mangaNumbersUseExistingFormatter(title: String, number: Double, expected: String) {
        let chapter = MangaChapter(tid: "42", rawTitle: title, chapterNumber: number)
        let item = ChapterDirectoryItem.manga(chapter, bookName: "Book", focusedID: "42", currentReadID: "other", progressText: "3")
        #expect(item.number == expected)
        #expect(item.id == chapter.tid)
        #expect(item.isFocused)
        #expect(!item.isCurrentRead)
        #expect(item.subtitle == L10n.string("forum.thread_route.current_chapter_hint"))
    }

    @Test func focusedChapterAndReadingPositionCanBothBeRepresented() {
        let chapter = MangaChapter(tid: "42", rawTitle: "第2话", chapterNumber: 2)
        let item = ChapterDirectoryItem.manga(chapter, bookName: "Book", focusedID: "42", currentReadID: "42", progressText: "第3页")
        #expect(item.isFocused && item.isCurrentRead)
        #expect(item.subtitle == "第3页")
        #expect(item.accessibilityValue.contains(L10n.string("forum.detail.current_read")))
        #expect(item.accessibilityValue.contains(L10n.string("forum.thread_route.current_chapter_hint")))
        #expect(item.informationText == "\(L10n.string("forum.detail.current_read")), 第3页")
    }

    @Test func focusedChapterHintIsNotRepeatedOrShownAsChapterInformation() {
        let chapter = MangaChapter(tid: "46", rawTitle: "第46话 心之鑰 / 你是音樂", chapterNumber: 46)
        let item = ChapterDirectoryItem.manga(chapter, bookName: "Madder & Teal", focusedID: "46", currentReadID: "40", progressText: "第1页")
        let hint = L10n.string("forum.thread_route.current_chapter_hint")
        #expect(item.subtitle == hint)
        #expect(item.accessibilityValue == hint)
        #expect(item.informationText.isEmpty)
        #expect(item.progressText == nil)
    }

    @Test func chapterInformationRetainsNovelReadingProgress() {
        let chapter = NovelChapterSummary(id: "page|post", title: "Chapter", view: 2, progressText: "35%", isCurrentRead: true)
        let item = ChapterDirectoryItem.novel(chapter, indexInPage: 0)
        #expect(item.subtitle == "35%")
        #expect(item.informationText == "\(L10n.string("forum.detail.current_read")), 35%")
    }

    @Test(arguments: [ChapterDirectoryLayout.list, .grid], [false, true])
    func currentReadingChapterNeverAddsAnOutline(layout: ChapterDirectoryLayout, focused: Bool) {
        let chapter = MangaChapter(tid: "46", rawTitle: "第46话", chapterNumber: 46)
        let item = ChapterDirectoryItem.manga(
            chapter, bookName: "Book", focusedID: focused ? "46" : "other",
            currentReadID: "46", progressText: "第1页"
        )
        #expect(item.isCurrentRead)
        #expect(item.isFocused == focused)
        #expect(item.outlineWidth(for: layout) == 0)
    }

    @Test(arguments: [ChapterDirectoryLayout.list, .grid], [false, true])
    func otherChaptersRetainFocusedOrDefaultOutlines(layout: ChapterDirectoryLayout, focused: Bool) {
        let chapter = MangaChapter(tid: "46", rawTitle: "第46话", chapterNumber: 46)
        let item = ChapterDirectoryItem.manga(
            chapter, bookName: "Book", focusedID: focused ? "46" : "other",
            currentReadID: "40", progressText: "第1页"
        )
        #expect(item.outlineWidth(for: layout) == (focused ? 2 : (layout == .grid ? 0.5 : 0)))
    }

    @Test func layoutAnchorUsesDisplayOrderAndSurvivesNewVisibilityCallbacks() {
        let anchor = ChapterDirectoryScrollAnchor(visibleIDs: ["chapter-9", "chapter-10", "chapter-8"])
        anchor.prepareLayoutChange(orderedIDs: ["chapter-7", "chapter-8", "chapter-9", "chapter-10"])
        anchor.visibleIDs = ["chapter-1", "chapter-2"]
        #expect(anchor.takePendingID(availableIDs: ["chapter-8", "chapter-9"]) == "chapter-8")
        #expect(anchor.takePendingID(availableIDs: ["chapter-8"]) == nil)
    }

    @Test func missingOrRemovedAnchorsDoNotJumpToAnotherChapter() {
        let anchor = ChapterDirectoryScrollAnchor(visibleIDs: ["missing"])
        anchor.prepareLayoutChange(orderedIDs: ["first", "second"])
        #expect(anchor.takePendingID(availableIDs: ["first", "second"]) == nil)
        anchor.visibleIDs = ["second"]
        anchor.prepareLayoutChange(orderedIDs: ["first", "second"])
        #expect(anchor.takePendingID(availableIDs: ["first"]) == nil)
    }

    @Test func restoredAnchorReservesPinnedToolbarSpace() {
        let anchor = ChapterDirectoryScrollAnchor.topAnchor(toolbarHeight: 60, viewportHeight: 400, itemHeight: 48)
        #expect(abs(anchor.y * (400 - 48) - 60) < 0.01)
        #expect(ChapterDirectoryScrollAnchor.topAnchor(toolbarHeight: 100, viewportHeight: 40, itemHeight: 48).y == 1)
    }
}

@MainActor
final class ContentDetailLayoutTests: XCTestCase {
    func testGridCellMaintainsSizeAcrossReadAndFocusedStates() {
        for current in [false, true] {
            for focused in [false, true] {
                let item = ChapterDirectoryItem(
                    id: "1", number: "123#", numberAccessibilityLabel: "123#",
                    title: "A long chapter title", isCurrentRead: current, isFocused: focused
                )
                let host = UIHostingController(rootView: ChapterDirectoryItemView(item: item, layout: .grid, action: {}))
                let size = host.sizeThatFits(in: CGSize(width: 56, height: 1000))
                XCTAssertEqual(size.width, 56, accuracy: 0.5)
                XCTAssertEqual(size.height, 48, accuracy: 0.5)
            }
        }
    }

    func testAccessibilityGridCellsGrowInsteadOfClipping() {
        let item = ChapterDirectoryItem(id: "1", number: "SP", numberAccessibilityLabel: "SP", title: "Special")
        let host = UIHostingController(rootView:
            ChapterDirectoryItemView(item: item, layout: .grid, action: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 120, height: 1000)).height, 48)
    }

    func testHeaderActionsWrapWithoutCompressingTargets() {
        let view = ContentDetailPrimaryActions {
            ContentDetailReadButton(hasProgress: true, action: {})
            ContentDetailFavoriteButton(isFavorited: false, action: {}, onLongPress: {})
            ContentDetailActionIcon(systemImage: "arrow.clockwise")
        }
        let host = UIHostingController(rootView: view)
        let wide = host.sizeThatFits(in: CGSize(width: 400, height: 1000))
        let narrow = host.sizeThatFits(in: CGSize(width: 160, height: 1000))
        XCTAssertGreaterThanOrEqual(wide.height, 48)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(narrow.width, 160, accuracy: 0.5)
    }

    func testReadingProgressStaysInlineWithoutIncreasingButtonHeight() {
        for progress in [nil, "", "  ", "第12话 · 第3页", String(repeating: "很长的章节标题和阅读进度", count: 30)] as [String?] {
            let view = ContentDetailPrimaryActions {
                ContentDetailReadButton(hasProgress: true, progressText: progress, action: {})
            }
            let size = UIHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: 288, height: 1000))
            XCTAssertEqual(size.height, 48, accuracy: 0.5)
            XCTAssertEqual(size.width, 288, accuracy: 0.5)
        }
        let newBook = ContentDetailPrimaryActions {
            ContentDetailReadButton(hasProgress: false, progressText: "Stale progress", action: {})
        }
        XCTAssertEqual(UIHostingController(rootView: newBook).sizeThatFits(in: CGSize(width: 288, height: 1000)).height, 48, accuracy: 0.5)
    }

    func testPrimaryActionFillsWidthAndSecondaryTargetsAlign() throws {
        for width: CGFloat in [288, 358, 398, 802] {
            let frames = try actionFrames(width: width)
            let read = try XCTUnwrap(frames["read"])
            let favorite = try XCTUnwrap(frames["favorite"])
            let update = try XCTUnwrap(frames["update"])
            XCTAssertEqual(read.minX, 0, accuracy: 0.5)
            XCTAssertEqual(update.maxX, width, accuracy: 0.5)
            XCTAssertEqual(favorite.width, 44, accuracy: 0.5)
            XCTAssertEqual(favorite.height, update.height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(favorite.height, 48)
            XCTAssertEqual(favorite.maxX + 8, update.minX, accuracy: 0.5)
            if width == 288 {
                XCTAssertEqual(read.width, width, accuracy: 0.5)
                XCTAssertEqual(favorite.minY, read.maxY + 8, accuracy: 0.5)
            } else {
                XCTAssertEqual(read.maxX + 8, favorite.minX, accuracy: 0.5)
                XCTAssertEqual(read.height, favorite.height, accuracy: 0.5)
                XCTAssertEqual(read.minY, favorite.minY, accuracy: 0.5)
            }
            for frame in frames.values {
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            }
        }
    }

    func testLargeActionsWrapWithoutClippingUpdateState() throws {
        let frames = try actionFrames(width: 288, dynamicTypeSize: .xxxLarge)
        let read = try XCTUnwrap(frames["read"])
        let update = try XCTUnwrap(frames["update"])
        XCTAssertEqual(read.width, 288, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(update.minY, read.maxY + 8)
        XCTAssertLessThanOrEqual(update.maxX, 288.5)
        XCTAssertGreaterThanOrEqual(update.height, 48)
    }

    func testNovelHeaderFitsLongTitleAndMissingMetadata() {
        var summary = NovelDetailHeaderSummary(
            title: "【自翻】【犬甘あんず】我心爱之人的妹妹 第一卷【完】", threadID: "1",
            authorID: "2", authorName: "誹夜", lastUpdatedText: "2025-7-14 22:15",
            totalViews: 47670, totalReplies: 298, chapterCount: 25,
            readingProgressText: String(repeating: "僅發佈在百合會論壇，請勿轉載至其他平台", count: 10), isFavorited: false
        )
        for missing in [false, true] {
            if missing {
                summary.authorID = nil
                summary.authorName = nil
                summary.lastUpdatedText = nil
                summary.totalViews = nil
                summary.totalReplies = nil
                summary.readingProgressText = nil
            }
            let header = NovelDetailHeader(
                summary: summary, canReadStart: true, hasReadingProgress: !missing,
                onFavoriteTap: {}, onFavoriteLongPress: {}, onAuthorTap: { _, _ in },
                onCopyText: nil, onReadStart: {}
            )
            for width: CGFloat in [320, 390, 430, 834] {
                for scheme in [ColorScheme.light, .dark] {
                    let size = UIHostingController(rootView: header.environment(\.colorScheme, scheme))
                        .sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertEqual(size.width, width, accuracy: 0.5)
                    XCTAssertLessThan(size.height, 300)
                    XCTAssertGreaterThanOrEqual(size.height, 104 * 112 / 86 + 10 + 48 + 24)
                }
            }
            let accessible = UIHostingController(rootView: header.environment(\.dynamicTypeSize, .accessibility3))
                .sizeThatFits(in: CGSize(width: 320, height: 1000))
            XCTAssertLessThan(accessible.height, 400)
        }
    }

    func testDirectoryScrollDoesNotMoveHeaderAndSwitchPreservesPosition() throws {
        let state = DirectoryFixtureState()
        let host = UIHostingController(rootView: DirectoryFixture(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        settle(host)
        let scroll = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UIScrollView }.first)
        let frame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertGreaterThan(frame.minY, 100)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertGreaterThan(scroll.contentOffset.y, 1000, "Initial entry should locate chapter 50")
        scroll.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        settle(host)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: host.view).minY, frame.minY, accuracy: 0.5)
        let picker = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UISegmentedControl }.first)
        picker.selectedSegmentIndex = 1
        selectSegment(1, in: picker)
        settle(host)
        XCTAssertEqual(state.layout, .grid)
        XCTAssertGreaterThan(scroll.contentOffset.y, 50, "Switching should not return to the first chapter")
        XCTAssertEqual(state.refreshCount, 0)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: host.view).minY, frame.minY, accuracy: 0.5)
        picker.selectedSegmentIndex = 0
        selectSegment(0, in: picker)
        settle(host)
        XCTAssertEqual(state.layout, .list)
        // At 390pt the grid has five columns. The first visible list chapter
        // (17) shares a grid row with chapter 16, so a round trip can retreat
        // only to that row's first chapter, not to the occluded preceding row.
        XCTAssertGreaterThanOrEqual(scroll.contentOffset.y, 719)
        XCTAssertLessThanOrEqual(scroll.contentOffset.y, 801)
    }

    func testMangaHeaderFitsNarrowAndCompactLayouts() {
        let directory = MangaDirectory(
            cleanBookName: "这是一本标题很长的漫画，需要换行但不能挤占整个章节列表",
            strategy: .tag,
            sourceKey: "test",
            chapters: [MangaChapter(tid: "1", rawTitle: "第一话", chapterNumber: 1)]
        )
        let header = MangaDetailHeader(
            directory: directory, coverURL: nil, latestChapterText: "第123话",
            readingProgressText: "第12话 · 第3页",
            hasReadingProgress: true, updateButtonTitle: "更新目录", isUpdateButtonEnabled: true,
            isSearchMode: false, isForcedSearchShortcutActive: false, isFavorited: false,
            onContinueTap: {}, onUpdateDirectoryTap: {}, onFavoriteTap: {},
            onFavoriteLongPress: {}, onCopyText: nil
        )
        let narrow = UIHostingController(rootView: header)
            .sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertLessThan(narrow.height, 300)
        XCTAssertEqual(narrow.width, 320, accuracy: 0.5)
        let compact = UIHostingController(rootView: header.environment(\.verticalSizeClass, .compact))
            .sizeThatFits(in: CGSize(width: 700, height: 1000))
        XCTAssertLessThan(compact.height, 210)
    }

    private func actionFrames(width: CGFloat, dynamicTypeSize: DynamicTypeSize = .large) throws -> [String: CGRect] {
        let recorder = ActionFrameRecorder()
        let host = UIHostingController(rootView: ActionLayoutFixture(recorder: recorder).environment(\.dynamicTypeSize, dynamicTypeSize))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        settle(host)
        XCTAssertEqual(recorder.frames.count, 3)
        return recorder.frames
    }

    private func settle(_ host: UIViewController) {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func selectSegment(_ index: Int, in picker: UISegmentedControl) {
        // This is a hostless unit-test target. Dispatch the control's registered
        // action directly because there is no UIApplication event dispatcher.
        if let action = picker.actionForSegment(at: index) {
            picker.sendAction(action)
        } else {
            for target in picker.allTargets {
                guard let object = target as? NSObject else { continue }
                for name in picker.actions(forTarget: object, forControlEvent: .valueChanged) ?? [] {
                    object.perform(NSSelectorFromString(name), with: picker)
                }
            }
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

}

@MainActor
private final class ActionFrameRecorder {
    var frames: [String: CGRect] = [:]
}

private struct ActionLayoutFixture: View {
    let recorder: ActionFrameRecorder

    var body: some View {
        ContentDetailPrimaryActions {
            ContentDetailReadButton(
                hasProgress: true,
                progressText: String(repeating: "第123话 · 很长的章节标题 · 第3页", count: 20), action: {}
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("actions")) } action: { recorder.frames["read"] = $0 }
            ContentDetailFavoriteButton(isFavorited: true, action: {}, onLongPress: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("actions")) } action: { recorder.frames["favorite"] = $0 }
            MangaDirectoryUpdateButton(
                title: "更新目录", isEnabled: true, isSearchMode: false,
                isForcedSearchShortcutActive: false, action: {}
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("actions")) } action: { recorder.frames["update"] = $0 }
        }
        .coordinateSpace(name: "actions")
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

@MainActor @Observable
private final class DirectoryFixtureState {
    var layout = ChapterDirectoryLayout.list
    var refreshCount = 0
}

private struct DirectoryFixture: View {
    @Bindable var state: DirectoryFixtureState
    private let sections: [ChapterDirectorySection] = Self.makeSections()

    private static func makeSections() -> [ChapterDirectorySection] {
        var items: [ChapterDirectoryItem] = []
        for index in 1...180 {
            let number = String(index)
            let item = ChapterDirectoryItem(
                id: number, number: number, numberAccessibilityLabel: number,
                title: "第 \(index) 章 这里是章节标题",
                isCurrentRead: index == 17, isFocused: index == 19
            )
            items.append(item)
        }
        return [ChapterDirectorySection(id: "1", items: items)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ContentDetailHeader(title: "小说与漫画详情", coverSource: nil, onCopyText: nil) { _ in
                Text("测试作者 · 更新于 2026-09-06")
                    .font(.caption)
            } actions: {
                ContentDetailPrimaryActions {
                    ContentDetailReadButton(hasProgress: true, action: {})
                    ContentDetailFavoriteButton(isFavorited: true, action: {}, onLongPress: {})
                }
            } details: {
                Text("作品信息")
            }
            ChapterDirectory(
                layout: $state.layout,
                sections: sections,
                countText: "180 项",
                initialFocusID: "50",
                refresh: { state.refreshCount += 1 },
                onChapterTap: { _ in },
                prelude: { EmptyView() }
            )
        }
    }
}
