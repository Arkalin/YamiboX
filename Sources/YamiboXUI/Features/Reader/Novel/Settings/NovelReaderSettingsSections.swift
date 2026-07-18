import SwiftUI
import YamiboXCore

#if os(iOS)

struct NovelReaderTextSection: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let onFontScaleChange: (Double) -> Void
    let onFontFamilyChange: (ReaderFontFamily) -> Void
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
                selectedFamily: settings.fontFamily,
                palette: palette,
                onSelect: onFontFamilyChange
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
                tint: YamiboColors.Site.orangeAccent,
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
                tint: YamiboColors.Site.orangeAccent,
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
                tint: YamiboColors.Site.orangeAccent,
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
    let showsTwoPageToggle: Bool
    @Binding var showsTwoPagesInLandscapeOnPad: Bool
    let onBackgroundStyleChange: (ReaderBackgroundStyle) -> Void
    let onReadingModeChange: (ReaderReadingMode, ReaderPagedTurnStyle) -> Void
    let onPageTurnDirectionChange: (ReaderPageTurnDirection) -> Void

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
                palette: palette
            ) { option in
                // Scroll mode has no turn style; keep the current one so it
                // is restored when the user returns to a paged mode.
                onReadingModeChange(option.readingMode, option.pagedTurnStyle ?? settings.pagedTurnStyle)
            }
            if settings.readingMode == .paged {
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsDirectionPicker(
                    title: L10n.string("reader.page_turn_direction"),
                    selection: settings.pageTurnDirection,
                    palette: palette,
                    onSelect: onPageTurnDirectionChange
                )
            }
            if showsTwoPageToggle {
                ReaderSettingsDivider(palette: palette)
                ReaderSettingsToggleRow(
                    title: L10n.string("reader.two_pages_landscape"),
                    palette: palette,
                    isOn: $showsTwoPagesInLandscapeOnPad
                )
            }
        }
    }
}

struct NovelReaderMiscSection: View {
    let palette: NovelReaderSheetPalette
    let loadsInlineImages: Bool
    let showsAuthorRepliesToOthers: Bool
    let onLoadsInlineImagesChange: (Bool) -> Void
    let onShowsAuthorRepliesToOthersChange: (Bool) -> Void

    var body: some View {
        ReaderSettingsSection(title: L10n.string("reader.section.other"), palette: palette) {
            ReaderSettingsToggleRow(
                title: L10n.string("reader.inline_images"),
                palette: palette,
                isOn: Binding(
                    get: { loadsInlineImages },
                    set: { onLoadsInlineImagesChange($0) }
                )
            )
            ReaderSettingsDivider(palette: palette)
            ReaderSettingsToggleRow(
                title: L10n.string("reader.author_replies_to_others"),
                palette: palette,
                isOn: Binding(
                    get: { showsAuthorRepliesToOthers },
                    set: { onShowsAuthorRepliesToOthersChange($0) }
                )
            )
        }
    }
}

#endif
