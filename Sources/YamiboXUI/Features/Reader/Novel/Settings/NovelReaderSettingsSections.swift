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
        NovelReaderSettingsSection(title: L10n.string("reader.section.text"), palette: palette) {
            NovelReaderFontScaleRow(
                value: settings.fontScale,
                palette: palette,
                onChange: onFontScaleChange
            )
            NovelReaderDivider(palette: palette)
            NovelReaderFontPickerRow(
                selectedFamily: settings.fontFamily,
                palette: palette,
                onSelect: onFontFamilyChange
            )
            NovelReaderDivider(palette: palette)
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
        NovelReaderSettingsSection(title: L10n.string("reader.section.layout"), palette: palette) {
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
            NovelReaderDivider(palette: palette)
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
            NovelReaderDivider(palette: palette)
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
            NovelReaderDivider(palette: palette)
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
        NovelReaderSettingsSection(title: L10n.string("reader.section.display"), palette: palette) {
            NovelReaderThemePicker(
                selectedStyle: settings.backgroundStyle,
                colorScheme: colorScheme,
                palette: palette,
                onSelect: onBackgroundStyleChange
            )
            NovelReaderDivider(palette: palette)
            NovelReaderReadingModePicker(
                settings: settings,
                palette: palette,
                onSelect: onReadingModeChange
            )
            if settings.readingMode == .paged {
                NovelReaderDivider(palette: palette)
                NovelReaderPageTurnDirectionPicker(
                    direction: settings.pageTurnDirection,
                    palette: palette,
                    onSelect: onPageTurnDirectionChange
                )
            }
            if showsTwoPageToggle {
                NovelReaderDivider(palette: palette)
                NovelReaderToggleRow(
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
        NovelReaderSettingsSection(title: L10n.string("reader.section.other"), palette: palette) {
            NovelReaderToggleRow(
                title: L10n.string("reader.inline_images"),
                palette: palette,
                isOn: Binding(
                    get: { loadsInlineImages },
                    set: { onLoadsInlineImagesChange($0) }
                )
            )
            NovelReaderDivider(palette: palette)
            NovelReaderToggleRow(
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
