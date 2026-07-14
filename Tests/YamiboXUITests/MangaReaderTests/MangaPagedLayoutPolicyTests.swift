import CoreGraphics
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("MangaReaderTests: Paged Layout Policy")
struct MangaPagedLayoutPolicyTests {
    @Test func twoPageSpreadActivatesOnlyForIPadPagedLandscapePreference() {
        let settings = MangaReaderSettings(
            readingMode: .paged,
            pageScaleMode: .fitHeight,
            showsTwoPagesInLandscapeOnPad: true
        )

        #expect(MangaPagedLayoutPolicy.usesTwoPageSpread(
            settings: settings,
            isPadDevice: true,
            availableSize: CGSize(width: 1180, height: 820)
        ))
        #expect(!MangaPagedLayoutPolicy.usesTwoPageSpread(
            settings: settings,
            isPadDevice: true,
            availableSize: CGSize(width: 820, height: 1180)
        ))
        #expect(!MangaPagedLayoutPolicy.usesTwoPageSpread(
            settings: settings,
            isPadDevice: false,
            availableSize: CGSize(width: 1180, height: 820)
        ))
    }

    @Test func twoPageSpreadRequiresPagedModeAndEnabledPreference() {
        let landscapeSize = CGSize(width: 1180, height: 820)
        let disabledSettings = MangaReaderSettings(
            readingMode: .paged,
            pageScaleMode: .fitHeight,
            showsTwoPagesInLandscapeOnPad: false
        )
        let verticalSettings = MangaReaderSettings(
            readingMode: .vertical,
            pageScaleMode: .fitHeight,
            showsTwoPagesInLandscapeOnPad: true
        )

        #expect(!MangaPagedLayoutPolicy.usesTwoPageSpread(
            settings: disabledSettings,
            isPadDevice: true,
            availableSize: landscapeSize
        ))
        #expect(!MangaPagedLayoutPolicy.usesTwoPageSpread(
            settings: verticalSettings,
            isPadDevice: true,
            availableSize: landscapeSize
        ))
    }

    @Test func twoPageSpreadForcesFitWidthWithoutMutatingSavedScalePreference() {
        let fitHeightSettings = MangaReaderSettings(
            readingMode: .paged,
            pageScaleMode: .fitHeight,
            showsTwoPagesInLandscapeOnPad: true
        )
        let fitWidthSettings = MangaReaderSettings(
            readingMode: .paged,
            pageScaleMode: .fitWidth,
            showsTwoPagesInLandscapeOnPad: false
        )

        #expect(MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: fitHeightSettings,
            usesTwoPageSpread: true
        ) == .fitWidth)
        #expect(fitHeightSettings.pageScaleMode == .fitHeight)
        #expect(MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: fitHeightSettings,
            usesTwoPageSpread: false
        ) == .fitHeight)
        #expect(MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: fitWidthSettings,
            usesTwoPageSpread: false
        ) == .fitWidth)
    }

    @Test func pagedContentTopInsetReservesSpaceOnlyWhenPagedAndToggleDisabled() {
        let pagedIgnoring = MangaReaderSettings(readingMode: .paged, ignoresTopSafeArea: true)
        let pagedRespecting = MangaReaderSettings(readingMode: .paged, ignoresTopSafeArea: false)
        let verticalRespecting = MangaReaderSettings(readingMode: .vertical, ignoresTopSafeArea: false)

        #expect(MangaPagedLayoutPolicy.pagedContentTopInset(settings: pagedIgnoring, topInset: 47) == 0)
        #expect(MangaPagedLayoutPolicy.pagedContentTopInset(settings: pagedRespecting, topInset: 47) == 47)
        #expect(MangaPagedLayoutPolicy.pagedContentTopInset(settings: verticalRespecting, topInset: 47) == 0)
    }

    @Test func mangaReaderSettingsDefaultsToIgnoringTopSafeArea() {
        #expect(MangaReaderSettings().ignoresTopSafeArea)
    }

    @Test func resizedViewportKeepsSameVisibleItemAtNewPageWidth() {
        let targetOffset = MangaPagedViewportResizePolicy.alignedContentOffsetX(
            previousContentOffsetX: 1_800,
            previousViewportSize: CGSize(width: 600, height: 840),
            currentViewportSize: CGSize(width: 480, height: 840),
            itemCount: 8
        )

        #expect(targetOffset == 1_440)
    }

    @Test func resizeAlignmentClampsToAvailableItemsAndIgnoresInitialLayout() {
        #expect(MangaPagedViewportResizePolicy.alignedContentOffsetX(
            previousContentOffsetX: 6_000,
            previousViewportSize: CGSize(width: 600, height: 840),
            currentViewportSize: CGSize(width: 480, height: 840),
            itemCount: 4
        ) == 1_440)

        #expect(MangaPagedViewportResizePolicy.alignedContentOffsetX(
            previousContentOffsetX: 600,
            previousViewportSize: nil,
            currentViewportSize: CGSize(width: 480, height: 840),
            itemCount: 4
        ) == nil)

        #expect(MangaPagedViewportResizePolicy.alignedContentOffsetX(
            previousContentOffsetX: 600,
            previousViewportSize: CGSize(width: 600, height: 840),
            currentViewportSize: CGSize(width: 600, height: 840),
            itemCount: 4
        ) == nil)
    }
}
