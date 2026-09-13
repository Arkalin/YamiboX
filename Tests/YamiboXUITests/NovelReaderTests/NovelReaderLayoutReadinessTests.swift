import Testing
@testable import YamiboXCore

struct NovelReaderLayoutReadinessTests {
    @Test func rejectsTransientOrNonfiniteBounds() {
        for layout in [
            NovelReaderLayout.zero,
            NovelReaderLayout(width: 119, height: 568),
            NovelReaderLayout(width: 320, height: 0),
            NovelReaderLayout(width: .infinity, height: 568),
            NovelReaderLayout(width: 320, height: .infinity),
            NovelReaderLayout(width: 160, height: 568, contentInsets: .init(leading: 24, trailing: 24)),
        ] {
            #expect(!layout.isReadyForTextLayout)
        }
        #expect(NovelReaderLayout(width: 120, height: 568).isReadyForTextLayout)
    }

    @Test func narrowWindowFallsBackToAReadableSinglePage() {
        var settings = NovelReaderAppearanceSettings(readingMode: .paged)
        settings.showsTwoPagesInLandscapeOnPad = true
        let layout = NovelReaderLayout(
            width: 280, height: 200,
            contentInsets: .init(leading: 24, trailing: 24)
        )
        #expect(layout.isReadyForTextLayout)
        #expect(!layout.usesTwoPageSpread(settings: settings, usesPadPresentation: true))
        #expect(layout.novelTextBoxLayout(settings: settings, usesPadPresentation: true).isReadyForTextLayout)
    }
}
