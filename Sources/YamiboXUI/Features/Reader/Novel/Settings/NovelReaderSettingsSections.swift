import SwiftUI
import YamiboXCore

#if os(iOS)

struct NovelReaderTextSection: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let onFontScaleChange: (Double) -> Void
    let fontTitle: String
    let onChooseFont: () -> Void
    let onSelectOriginalText: () -> Void
    let onSelectSimplifiedText: () -> Void
    let onSelectTraditionalText: () -> Void

    var body: some View {
        ReaderSettingsSection(title: L10n.string("reader.section.text"), palette: palette) {
            NovelReaderFontScaleRow(
                value: settings.fontScale,
                palette: palette,
                onChange: onFontScaleChange
            )
            ReaderSettingsDivider(palette: palette)
            NovelReaderFontPickerRow(
                title: fontTitle,
                palette: palette,
                onSelect: onChooseFont
            )
            ReaderSettingsDivider(palette: palette)
            NovelReaderTranslationPicker(
                selectedModeRawValue: settings.translationMode.rawValue,
                palette: palette,
                onSelectOriginal: onSelectOriginalText,
                onSelectSimplified: onSelectSimplifiedText,
                onSelectTraditional: onSelectTraditionalText
            )
        }
    }
}

struct NovelReaderLayoutSection: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let onLineHeightChange: (Double) -> Void
    let onCharacterSpacingChange: (Double) -> Void
    let onHorizontalPaddingChange: (Double) -> Void

    var body: some View {
        ReaderSettingsSection(title: L10n.string("reader.section.layout"), palette: palette) {
            NovelReaderSliderRow(
                title: L10n.string("reader.line_height"),
                valueLabel: String(format: "%.2f", settings.lineHeightScale),
                value: settings.lineHeightScale,
                range: 1.2 ... 2.2,
                step: 0.05,
                icon: .system("text.line.first.and.arrowtriangle.forward"),
                tint: palette.controlAccent,
                palette: palette,
                onChange: onLineHeightChange
            )
            ReaderSettingsDivider(palette: palette)
            NovelReaderSliderRow(
                title: L10n.string("reader.character_spacing"),
                valueLabel: "\(Int((settings.characterSpacingScale * 100).rounded()))%",
                value: settings.characterSpacingScale,
                range: 0 ... 0.12,
                step: 0.01,
                icon: .characterSpacing,
                tint: palette.controlAccent,
                palette: palette,
                onChange: onCharacterSpacingChange
            )
            ReaderSettingsDivider(palette: palette)
            NovelReaderSliderRow(
                title: L10n.string("reader.horizontal_padding"),
                valueLabel: "\(Int(settings.horizontalPadding.rounded()))",
                value: settings.horizontalPadding,
                range: 8 ... 36,
                step: 2,
                icon: .system("rectangle.inset.filled"),
                tint: palette.controlAccent,
                palette: palette,
                onChange: onHorizontalPaddingChange
            )
        }
    }
}

struct NovelReaderTextOptionsSection: View {
    let palette: NovelReaderSheetPalette
    @Binding var usesJustifiedText: Bool
    @Binding var indentsParagraphFirstLine: Bool

    var body: some View {
        VStack(spacing: 0) {
            toggleRow(
                title: L10n.string("reader.justified_text"),
                isOn: $usesJustifiedText
            )
            ReaderSettingsDivider(palette: palette)
            toggleRow(
                title: L10n.string("reader.paragraph_first_line_indent"),
                isOn: $indentsParagraphFirstLine
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(palette.divider, lineWidth: 1)
        }
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.title3)
                .foregroundStyle(palette.primaryText)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

struct NovelReaderDisplaySection: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let colorScheme: ColorScheme
    let onBackgroundStyleChange: (ReaderBackgroundStyle) -> Void
    let onReadingModeChange: (ReaderReadingMode, ReaderPagedTurnStyle) -> Void
    let onPageTurnDirectionChange: (ReaderPageTurnDirection) -> Void
    let onImmersiveModeChange: (Bool) -> Void

    var body: some View {
        ReaderSettingsSection(title: L10n.string("reader.section.display"), palette: palette) {
            NovelReaderThemePicker(
                selectedStyle: settings.backgroundStyle,
                colorScheme: colorScheme,
                palette: palette,
                onSelect: onBackgroundStyleChange
            )
            ReaderSettingsDivider(palette: palette)
            ReaderSettingsModePicker(
                selection: ReaderSettingsReadingModeOption(settings),
                pagedTurnStyle: settings.pagedTurnStyle,
                palette: palette
            ) { option in
                onReadingModeChange(option.readingMode, settings.pagedTurnStyle)
            } onSelectAnimation: { style in
                onReadingModeChange(settings.readingMode, style)
            }
            if settings.readingMode == .paged {
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsDirectionPicker(
                    title: L10n.string("reader.page_turn_direction"),
                    selection: settings.pageTurnDirection,
                    palette: palette,
                    onSelect: onPageTurnDirectionChange
                )
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsToggleRow(
                    title: L10n.string("reader.immersive_mode"),
                    palette: palette,
                    isOn: Binding(
                        get: { settings.isImmersiveModeEnabled },
                        set: { onImmersiveModeChange($0) }
                    )
                )
            }
        }
    }
}

struct NovelReaderMiscSection: View {
    let palette: NovelReaderSheetPalette
    let onOpenForumFormat: () -> Void
    let onOpenPeripheralSettings: () -> Void

    var body: some View {
        ReaderSettingsSection(title: L10n.string("reader.section.other"), palette: palette) {
            ReaderSettingsNavigationRow(
                title: L10n.string("reader.forum_format"),
                palette: palette,
                action: onOpenForumFormat
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

struct NovelReaderForumFormatSheet: View {
    @Binding var settings: NovelReaderAppearanceSettings
    let controlAccent: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NovelReaderSheetPalette(settings: settings, colorScheme: colorScheme, controlAccent: controlAccent)
        NavigationStack {
            ScrollView {
                ReaderSettingsSection(title: L10n.string("reader.forum_format"), palette: palette) {
                    formatToggle("reader.forum_format.bold", palette: palette, isOn: $settings.forumFormat.bold)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.italic", palette: palette, isOn: $settings.forumFormat.italic)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.underline", palette: palette, isOn: $settings.forumFormat.underline)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.strikethrough", palette: palette, isOn: $settings.forumFormat.strikethrough)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.text_color", palette: palette, isOn: $settings.forumFormat.textColor)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.background_color", palette: palette, isOn: $settings.forumFormat.backgroundColor)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.ruby", palette: palette, isOn: $settings.forumFormat.ruby)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.quote", palette: palette, isOn: $settings.forumFormat.quote)
                    formatDivider(palette)
                    formatToggle("reader.forum_format.images", palette: palette, isOn: $settings.loadsInlineImages)
                }
                .padding(20)
            }
            .background(palette.bodyBackground.ignoresSafeArea())
            .navigationTitle(L10n.string("reader.forum_format"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
        }
        .tint(controlAccent)
    }

    private func formatToggle(
        _ key: String,
        palette: NovelReaderSheetPalette,
        isOn: Binding<Bool>
    ) -> some View {
        ReaderSettingsToggleRow(title: L10n.string(key), palette: palette, isOn: isOn)
    }

    private func formatDivider(_ palette: NovelReaderSheetPalette) -> some View {
        ReaderSettingsDivider(palette: palette)
    }
}

#endif
