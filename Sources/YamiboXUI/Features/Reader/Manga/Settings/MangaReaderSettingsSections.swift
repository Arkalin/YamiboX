import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsSections: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let isPadDevice: Bool
    let usesTwoPageSpread: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                MangaReaderSettingsDisplaySection(
                    settings: $settings,
                    palette: palette
                )

                MangaReaderSettingsPagingSection(
                    settings: $settings,
                    palette: palette,
                    isPadDevice: isPadDevice,
                    usesTwoPageSpread: usesTwoPageSpread
                )
            }
            .padding(.top, 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
    }
}

private struct MangaReaderSettingsDisplaySection: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette

    var body: some View {
        MangaReaderSettingsCardSection(
            title: L10n.string("manga.settings.section.display"),
            palette: palette
        ) {
            MangaReaderBrightnessRow(
                value: $settings.brightness,
                palette: palette
            )
            MangaReaderSettingsDivider(palette: palette)
            MangaReaderSettingsToggleRow(
                title: L10n.string("manga.double_tap_zoom"),
                palette: palette,
                isOn: $settings.zoomEnabled
            )
        }
    }
}

private struct MangaReaderSettingsPagingSection: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let isPadDevice: Bool
    let usesTwoPageSpread: Bool

    var body: some View {
        MangaReaderSettingsCardSection(
            title: L10n.string("manga.settings.section.paging"),
            palette: palette
        ) {
            MangaReaderModePicker(
                settings: $settings,
                palette: palette
            )

            if settings.usesPagedMode {
                if isPadDevice {
                    MangaReaderSettingsDivider(palette: palette)
                    MangaReaderSettingsToggleRow(
                        title: L10n.string("reader.two_pages_landscape"),
                        palette: palette,
                        isOn: $settings.showsTwoPagesInLandscapeOnPad
                    )
                }
                MangaReaderSettingsDivider(palette: palette)
                MangaReaderDirectionPicker(
                    direction: $settings.pageTurnDirection,
                    palette: palette
                )
                MangaReaderSettingsDivider(palette: palette)
                if !usesTwoPageSpread {
                    MangaReaderPageScaleModeMenuRow(
                        scaleMode: $settings.pageScaleMode,
                        palette: palette
                    )
                    MangaReaderSettingsDivider(palette: palette)
                }
                MangaReaderPageEdgeFillMenuRow(
                    edgeFillStyle: $settings.pageEdgeFillStyle,
                    palette: palette
                )
                MangaReaderSettingsDivider(palette: palette)
                MangaReaderSettingsToggleRow(
                    title: L10n.string("manga.ignores_top_safe_area"),
                    palette: palette,
                    isOn: $settings.ignoresTopSafeArea
                )
            }
        }
    }
}
#endif
