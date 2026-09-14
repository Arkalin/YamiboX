import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("Reader page information")
struct ReaderPageInformationTests {
    @Test func visibilityMatrixAndPhysicalTitles() {
        for paged in [true, false] {
            for immersive in [true, false] {
                for chrome in [true, false] {
                    let state = ReaderPageInformationPresentation(isPaged: paged, isImmersive: immersive, isChromeVisible: chrome)
                    let visible = chrome || (paged && !immersive)
                    #expect(state.isVisible == visible)
                    #expect(state.pageNumberStyle == (chrome ? .full : visible ? .compact : .hidden))
                    let chapter = state.chapterText(title: "Chapter", remainingPages: 3)
                    #expect(chapter == (paged && !immersive && chrome ? L10n.string("reader.chapter_pages_remaining", 3) : "Chapter"))
                    #expect(state.chapterText(title: "Chapter", remainingPages: 0)
                        == (paged && !immersive && chrome ? L10n.string("reader.chapter_last_page") : "Chapter"))
                    for rtl in [true, false] {
                        #expect(state.titles(work: "Book", chapter: chapter, isRightToLeft: rtl)
                            == (rtl ? [chapter, "Book"] : ["Book", chapter]))
                        #expect(state.titles(work: nil, chapter: chapter, isRightToLeft: rtl) == [chapter])
                    }
                }
            }
        }
    }

    @Test func persistedSettingsRoundTripAndLegacyDefaults() throws {
        var settings = AppSettings(
            novelReader: NovelReaderAppearanceSettings(isImmersiveModeEnabled: true, fontScale: 1.3, readingMode: .paged),
            manga: MangaReaderSettings(isImmersiveModeEnabled: true, pageTurnDirection: .rightToLeft, brightness: 0.6)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(settings)
        #expect(try decoder.decode(AppSettings.self, from: data) == settings)
        var disabledSettings = settings
        disabledSettings.manga.isImmersiveModeEnabled = false
        #expect(try decoder.decode(AppSettings.self, from: encoder.encode(disabledSettings)) == disabledSettings)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["novelReader", "manga"] {
            var reader = try #require(legacy[key] as? [String: Any])
            reader.removeValue(forKey: "isImmersiveModeEnabled")
            legacy[key] = reader
        }
        settings.novelReader.isImmersiveModeEnabled = false
        settings.manga.isImmersiveModeEnabled = true
        #expect(try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy)) == settings)
        #expect(!NovelReaderAppearanceSettings().isImmersiveModeEnabled)
        #expect(MangaReaderSettings().isImmersiveModeEnabled)
    }

    @Test func novelRemainingPagesRespectChapterBoundariesAndVisibleSpread() {
        for direction in [ReaderPageTurnDirection.leftToRight, .rightToLeft] {
            for spread in [true, false] {
                for index in 0..<7 {
                    let snapshot = makeNovelSnapshot(index: index, spread: spread, direction: direction)
                    let anchor = spread && direction == .leftToRight ? min(index - index % 2 + 1, 6)
                        : spread ? index - index % 2 : index
                    let end = anchor < 3 ? 3 : anchor < 5 ? 5 : 7
                    let lastVisible = spread ? min(index - index % 2 + 1, 6) : index
                    let lastInChapter = min(lastVisible, end - 1)
                    #expect(snapshot.remainingChapterPageCount == max(end - lastInChapter - 1, 0))
                    if spread {
                        let left = index - index % 2
                        #expect(snapshot.spreadPageNumbers == [left + 1, left + 1 < 7 ? left + 2 : nil])
                    } else {
                        #expect(snapshot.pageNumber == index + 1)
                        #expect(snapshot.spreadPageNumbers == nil)
                    }
                }
            }
        }
        // Multiple chapter headings on one rendered page must not yield a negative count.
        #expect(makeNovelSnapshot(index: 3, spread: false, direction: .leftToRight, starts: [0, 3, 3, 5]).remainingChapterPageCount == 1)
        #expect(makeNovelSnapshot(index: 6, spread: false, direction: .leftToRight).remainingChapterPageCount == 0)
    }

    private func makeNovelSnapshot(
        index: Int, spread: Bool, direction: ReaderPageTurnDirection, starts: [Int] = [0, 3, 5]
    ) -> NovelReaderChromeProgressSnapshot {
        NovelReaderChromeProgressSnapshot(presentation: makeNovelPresentation(index: index, spread: spread, direction: direction, starts: starts))
    }

    @Test func attachedNovelPagesUseTheirOwnAnchorsAndWebPageNumbers() {
        for direction in [ReaderPageTurnDirection.leftToRight, .rightToLeft] {
            for spread in [true, false] {
                for immersive in [true, false] {
                    for chrome in [true, false] {
                        let information = ReaderPageInformationPresentation(isPaged: true, isImmersive: immersive, isChromeVisible: chrome)
                        let presentation = makeNovelPresentation(index: 0, spread: spread, direction: direction, views: [1, 1, 1, 2, 2, 2, 2])
                        let pages = NovelAttachedPageInformation.pages(presentation: presentation, workTitle: "Book", information: information)
                        for (groupIndex, group) in pages.enumerated() {
                            let first = spread ? groupIndex * 2 : groupIndex
                            let anchor = spread && direction == .leftToRight ? min(first + 1, 6) : first
                            let end = anchor < 3 ? 3 : anchor < 5 ? 5 : 7
                            let lastVisible = spread ? min(first + 1, 6) : first
                            let remaining = max(end - min(lastVisible, end - 1) - 1, 0)
                            let title = information.chapterText(title: "Chapter", remainingPages: remaining)
                            #expect(group.map(\.title) == information.titles(work: spread ? "Book" : nil, chapter: title, isRightToLeft: direction == .rightToLeft))
                            for (slot, page) in group.enumerated() {
                                let index = first + slot
                                #expect(page.pageNumber == (index < 7 ? (index < 3 ? index + 1 : index - 2) : nil))
                                #expect((page.pageID == nil) == (index >= 7))
                                if index < 7 { #expect(!page.webLine.isEmpty) }
                            }
                        }
                        let restored = makeNovelPresentation(index: 6, spread: spread, direction: direction, views: [1, 1, 1, 2, 2, 2, 2])
                        #expect(pages == NovelAttachedPageInformation.pages(presentation: restored, workTitle: "Book", information: information))
                    }
                }
            }
        }
    }

    @Test @MainActor func informationUpdatesDoNotChangePagedContentIdentity() {
        let state = ReaderAttachedInformationState()
        let settings = NovelReaderAppearanceSettings(readingMode: .paged)
        var immersiveSettings = settings
        immersiveSettings.isImmersiveModeEnabled.toggle()
        let url = URL(string: "https://example.com")!
        let before = NovelReaderPagedViewportContentIdentity(surfaces: [], settings: settings, refererURL: url, topInset: 80, bottomInset: 30)
        let after = NovelReaderPagedViewportContentIdentity(surfaces: [], settings: immersiveSettings, refererURL: url, topInset: 80, bottomInset: 30)
        #expect(before == after)
        var configuration = ReaderAttachedInformationConfiguration(selectedIndex: 3, topInset: 32, bottomInset: 20)
        state.update(configuration)
        state.usesStationaryZoomInformation = true
        configuration.presentation = ReaderPageInformationPresentation(isPaged: true, isImmersive: false, isChromeVisible: true)
        state.update(configuration)
        #expect(state.configuration.selectedIndex == 3)
        #expect(state.configuration.topInset == 32)
        #expect(state.usesStationaryZoomInformation)
    }

    private func makeNovelPresentation(
        index: Int, spread: Bool, direction: ReaderPageTurnDirection, starts: [Int] = [0, 3, 5], views: [Int] = Array(repeating: 1, count: 7)
    ) -> NovelReaderPresentation {
        let surfaces = (0..<7).map { index in
            NovelReaderSurface(identity: NovelReaderSurfaceIdentity(generation: 1, ordinal: index),
                presentationIndex: index, kind: .text, documentView: views[index], chapterTitle: "Chapter", presentationSize: .zero)
        }
        let spreads = stride(from: 0, to: 7, by: 2).map { index in
            NovelReaderPresentationSpread(index: index / 2, leftSurfaceIndex: index,
                leftSurfaceIdentity: surfaces[index].identity, rightSurfaceIndex: index + 1 < 7 ? index + 1 : nil,
                rightSurfaceIdentity: index + 1 < 7 ? surfaces[index + 1].identity : nil, chapterTitle: "Chapter")
        }
        return NovelReaderPresentation(
            generation: 1, revision: 1, surfaces: surfaces, selectedSurfaceIdentity: surfaces[index].identity,
            spreads: spreads, chapters: starts.enumerated().map { NovelReaderChapter(ordinal: $0.offset, title: "Chapter", startIndex: $0.element) },
            committedSettings: NovelReaderAppearanceSettings(readingMode: .paged, pageTurnDirection: direction),
            readingState: NovelReaderReadingState(currentView: 1, maxView: 1, currentChapterTitle: "Chapter", authorID: nil, currentSurfaceIntraProgress: 0),
            retainedChapterCount: starts.count, filteredChapterCandidateCount: 0, usesTwoPageSpread: spread
        )
    }
}
