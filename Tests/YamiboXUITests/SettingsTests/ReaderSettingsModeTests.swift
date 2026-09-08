#if os(iOS)
import Testing
import YamiboXCore
@testable import YamiboXUI

@Suite("Reading mode selection")
struct ReaderSettingsModeTests {
    @Test(arguments: ReaderPagedTurnStyle.allCases)
    func mangaModeChangesPreserveRememberedAnimation(style: ReaderPagedTurnStyle) {
        var settings = MangaReaderSettings(readingMode: .paged, pagedTurnStyle: style)
        #expect(ReaderSettingsReadingModeOption(settings) == .paged)
        settings.selectMode(.scroll)
        #expect(settings.readingMode == .vertical)
        #expect(ReaderSettingsReadingModeOption(settings) == .scroll)
        #expect(settings.pagedTurnStyle == style)
        settings.selectMode(.paged)
        #expect(settings.readingMode == .paged)
        #expect(settings.pagedTurnStyle == style)
    }

    @Test(arguments: ReaderPagedTurnStyle.allCases)
    func novelModeSelectionDoesNotDependOnAnimation(style: ReaderPagedTurnStyle) {
        var settings = NovelReaderAppearanceSettings(readingMode: .paged, pagedTurnStyle: style)
        #expect(ReaderSettingsReadingModeOption(settings) == .paged)
        settings.readingMode = ReaderSettingsReadingModeOption.scroll.readingMode
        #expect(ReaderSettingsReadingModeOption(settings) == .scroll)
        settings.readingMode = ReaderSettingsReadingModeOption.paged.readingMode
        #expect(settings.readingMode == .paged)
        #expect(settings.pagedTurnStyle == style)
    }
}
#endif
