import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsSections: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let onOpenPeripheralSettings: () -> Void
    let onOpenGestureRegions: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                MangaReaderSettingsPagingSection(
                    settings: $settings,
                    palette: palette,
                    usesTwoPageSpread: usesTwoPageSpread,
                    onOpenGestureRegions: onOpenGestureRegions
                )

                MangaReaderSettingsOtherSection(
                    zoomEnabled: $settings.zoomEnabled,
                    zoomAnimationEnabled: $settings.zoomAnimationEnabled,
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

struct MangaReaderSettingsPagingSection: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool
    let onOpenGestureRegions: () -> Void

    var body: some View {
        ReaderSettingsSection(
            title: L10n.string("reader.section.display"),
            palette: palette
        ) {
            MangaReaderBrightnessRow(value: $settings.brightness, palette: palette)
            ReaderSettingsDivider(palette: palette)
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
                ReaderSettingsNavigationRow(
                    title: L10n.string("reader.gesture_regions.title"),
                    palette: palette,
                    value: settings.gestureRegionLayout.title,
                    action: onOpenGestureRegions
                )
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
    @Binding var zoomAnimationEnabled: Bool
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
            if zoomEnabled {
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsToggleRow(
                    title: L10n.string("manga.zoom_animation"),
                    palette: palette,
                    isOn: $zoomAnimationEnabled
                )
            }
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
