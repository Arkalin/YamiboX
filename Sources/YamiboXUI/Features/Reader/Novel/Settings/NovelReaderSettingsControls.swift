import SwiftUI
import YamiboXCore

#if os(iOS)

// The section card, divider, toggle row, mode/direction pickers, and the
// round stepper button are shared with the Manga sheet — see
// Reader/Shared/Settings. This file keeps only the Novel-specific rows
// (typography, translation, background theme) and the mapping between Novel
// settings and the shared option types.

struct NovelReaderFontScaleRow: View {
    let value: Double
    let palette: NovelReaderSheetPalette
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("reader.font_size"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text(String(format: "%.1f", value))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 14) {
                // 44pt is the Novel sheet's original size; Manga uses 42pt.
                ReaderSettingsStepperButton(
                    systemName: "minus",
                    palette: palette,
                    diameter: 44
                ) {
                    onChange(max(0.8, value - 0.1))
                }

                Slider(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            let stepped = (newValue / 0.1).rounded() * 0.1
                            onChange(min(2.3, max(0.8, stepped)))
                        }
                    ),
                    in: 0.8 ... 2.3
                )
                .tint(YamiboColors.Site.orangeAccent)

                ReaderSettingsStepperButton(
                    systemName: "plus",
                    palette: palette,
                    diameter: 44
                ) {
                    onChange(min(2.3, value + 0.1))
                }
            }
        }
    }
}

struct NovelReaderFontPickerRow: View {
    let selectedFamily: ReaderFontFamily
    let palette: NovelReaderSheetPalette
    let onSelect: (ReaderFontFamily) -> Void

    var body: some View {
        HStack {
            Text(L10n.string("reader.font_family"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Spacer()
            Menu {
                ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                    Button(family.title) {
                        onSelect(family)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedFamily.title)
                        .foregroundStyle(palette.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct NovelReaderSliderRow: View {
    let title: String
    let valueLabel: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let icon: NovelReaderSliderIcon
    let tint: Color
    let palette: NovelReaderSheetPalette
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 16) {
                NovelReaderSliderLeadingIcon(
                    icon: icon,
                    palette: palette
                )
                    .frame(width: 26)

                Slider(
                    value: Binding(
                        get: { value },
                        set: { newValue in
                            let stepped = (newValue / step).rounded() * step
                            onChange(min(range.upperBound, max(range.lowerBound, stepped)))
                        }
                    ),
                    in: range
                )
                .tint(tint)

                Text(valueLabel)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
    }
}

enum NovelReaderSliderIcon {
    case system(String)
    case characterSpacing
}

struct NovelReaderSliderLeadingIcon: View {
    let icon: NovelReaderSliderIcon
    let palette: NovelReaderSheetPalette

    var body: some View {
        switch icon {
        case let .system(name):
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(palette.primaryText)
        case .characterSpacing:
            VStack(spacing: -1) {
                Text(L10n.string("reader.character_spacing_sample"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
            }
            .frame(minWidth: 26, minHeight: 24)
        }
    }
}

extension ReaderSettingsReadingModeOption {
    /// Maps Novel settings onto the shared option; Manga keeps the same
    /// shape of initializer next to its own settings type.
    init(_ settings: NovelReaderAppearanceSettings) {
        self.init(
            isPaged: settings.readingMode == .paged,
            pagedTurnStyle: settings.pagedTurnStyle
        )
    }
}

struct NovelReaderTranslationPicker: View {
    let selectedModeRawValue: String
    let palette: NovelReaderSheetPalette
    let onSelectOriginal: () -> Void
    let onSelectSimplified: () -> Void
    let onSelectTraditional: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("translation.title"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 8) {
                translationButton(L10n.string("translation.original"), modeRawValue: ReaderTranslationMode.none.rawValue, action: onSelectOriginal)
                translationButton(L10n.string("translation.simplified"), modeRawValue: ReaderTranslationMode.simplified.rawValue, action: onSelectSimplified)
                translationButton(L10n.string("translation.traditional"), modeRawValue: ReaderTranslationMode.traditional.rawValue, action: onSelectTraditional)
            }
            .padding(6)
            .background(palette.segmentedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func translationButton(_ title: String, modeRawValue: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    selectedModeRawValue == modeRawValue ? palette.cardBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .foregroundStyle(palette.primaryText)
        }
        .buttonStyle(.plain)
    }
}

struct NovelReaderThemePicker: View {
    let selectedStyle: ReaderBackgroundStyle
    let colorScheme: ColorScheme
    let palette: NovelReaderSheetPalette
    let onSelect: (ReaderBackgroundStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reader.background_theme"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 12) {
                ForEach(ReaderBackgroundStyle.allCases, id: \.self) { style in
                    Button {
                        onSelect(style)
                    } label: {
                        VStack(spacing: 10) {
                            Circle()
                                .fill(readerThemeColor(for: style, colorScheme: colorScheme))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Circle()
                                        .strokeBorder(selectedStyle == style ? palette.primaryText : Color.clear, lineWidth: 2)
                                }
                            Text(style.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.primaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedStyle == style ? palette.primaryText.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#endif
