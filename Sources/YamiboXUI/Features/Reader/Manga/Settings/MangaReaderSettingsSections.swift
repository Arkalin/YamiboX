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
        ReaderSettingsSection(
            title: L10n.string("manga.settings.section.display"),
            palette: palette
        ) {
            MangaReaderBrightnessRow(
                value: $settings.brightness,
                palette: palette
            )
            ReaderSettingsDivider(palette: palette)
            ReaderSettingsToggleRow(
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
        ReaderSettingsSection(
            title: L10n.string("manga.settings.section.paging"),
            palette: palette
        ) {
            ReaderSettingsModePicker(
                selection: ReaderSettingsReadingModeOption(settings),
                palette: palette
            ) { option in
                settings.selectMode(option)
            }

            if settings.usesPagedMode {
                if isPadDevice {
                    ReaderSettingsDivider(palette: palette)
                    ReaderSettingsToggleRow(
                        title: L10n.string("reader.two_pages_landscape"),
                        palette: palette,
                        isOn: $settings.showsTwoPagesInLandscapeOnPad
                    )
                }
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsDirectionPicker(
                    title: L10n.string("manga.page_turn_direction"),
                    selection: settings.pageTurnDirection,
                    palette: palette
                ) { direction in
                    settings.pageTurnDirection = direction
                }
                ReaderSettingsDivider(palette: palette)
                if !usesTwoPageSpread {
                    MangaReaderSettingsMenuRow(
                        title: L10n.string("manga.page_scale_mode"),
                        selection: $settings.pageScaleMode,
                        palette: palette
                    )
                    ReaderSettingsDivider(palette: palette)
                }
                MangaReaderSettingsMenuRow(
                    title: L10n.string("manga.page_edge_fill"),
                    selection: $settings.pageEdgeFillStyle,
                    palette: palette
                )
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsToggleRow(
                    title: L10n.string("manga.ignores_top_safe_area"),
                    palette: palette,
                    isOn: $settings.ignoresTopSafeArea
                )
            }
        }
    }
}
#endif
