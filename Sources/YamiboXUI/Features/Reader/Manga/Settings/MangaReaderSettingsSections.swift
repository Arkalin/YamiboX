import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsSections: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let onOpenPeripheralSettings: () -> Void

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
                    usesTwoPageSpread: usesTwoPageSpread
                )

                MangaReaderSettingsOtherSection(
                    zoomEnabled: $settings.zoomEnabled,
                    palette: palette,
                    onOpenPeripheralSettings: onOpenPeripheralSettings
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
        }
    }
}

struct MangaReaderSettingsPagingSection: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool

    var body: some View {
        ReaderSettingsSection(
            title: L10n.string("manga.settings.section.paging"),
            palette: palette
        ) {
            ReaderSettingsModePicker(
                selection: ReaderSettingsReadingModeOption(settings),
                pagedTurnStyle: settings.pagedTurnStyle,
                palette: palette
            ) { option in
                settings.selectMode(option)
            } onSelectAnimation: { style in
                settings.pagedTurnStyle = style
            }

            if settings.usesPagedMode {
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsDirectionPicker(
                    title: L10n.string("manga.page_turn_direction"),
                    selection: settings.pageTurnDirection,
                    palette: palette
                ) { direction in
                    settings.pageTurnDirection = direction
                }
                ReaderSettingsDivider(palette: palette)
                MangaReaderPagedDisplaySettings(
                    settings: $settings,
                    palette: palette,
                    usesTwoPageSpread: usesTwoPageSpread
                )
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsToggleRow(
                    title: L10n.string("reader.immersive_mode"),
                    palette: palette,
                    isOn: $settings.isImmersiveModeEnabled
                )
            }
        }
    }
}

private struct MangaReaderSettingsOtherSection: View {
    @Binding var zoomEnabled: Bool
    let palette: MangaReaderSettingsPalette
    let onOpenPeripheralSettings: () -> Void

    var body: some View {
        ReaderSettingsSection(
            title: L10n.string("reader.section.other"),
            palette: palette
        ) {
            ReaderSettingsToggleRow(
                title: L10n.string("manga.double_tap_zoom"),
                palette: palette,
                isOn: $zoomEnabled
            )
            ReaderSettingsDivider(palette: palette)
            ReaderSettingsNavigationRow(
                title: L10n.string("settings.peripheral_behavior"),
                palette: palette,
                action: onOpenPeripheralSettings
            )
        }
    }
}
#endif
