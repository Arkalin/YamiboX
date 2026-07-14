import SwiftUI
import YamiboXCore

#if os(iOS)

struct NovelReaderSettingsSection<Content: View>: View {
    let title: String
    let palette: NovelReaderSheetPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(palette.divider, lineWidth: 1)
            }
        }
    }
}

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
                circleButton(systemName: "minus") {
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

                circleButton(systemName: "plus") {
                    onChange(min(2.3, value + 0.1))
                }
            }
        }
    }

    private func circleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 44, height: 44)
                .background(palette.segmentedBackground, in: Circle())
        }
        .buttonStyle(.plain)
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

struct NovelReaderToggleRow: View {
    let title: String
    let palette: NovelReaderSheetPalette
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.title3)
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
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

struct NovelReaderReadingModePicker: View {
    let settings: NovelReaderAppearanceSettings
    let palette: NovelReaderSheetPalette
    let onSelect: (ReaderReadingMode, ReaderPagedTurnStyle) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var selectedMode: NovelReaderReadingModeOption {
        NovelReaderReadingModeOption(settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reading_mode.title"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(NovelReaderReadingModeOption.allCases, id: \.self) { option in
                    NovelReaderReadingModeButton(
                        option: option,
                        isSelected: selectedMode == option,
                        palette: palette
                    ) {
                        onSelect(option.readingMode, option.pagedTurnStyle ?? settings.pagedTurnStyle)
                    }
                }
            }
        }
    }
}

struct NovelReaderPageTurnDirectionPicker: View {
    let direction: ReaderPageTurnDirection
    let palette: NovelReaderSheetPalette
    let onSelect: (ReaderPageTurnDirection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reader.page_turn_direction"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 8) {
                ForEach(ReaderPageTurnDirection.allCases, id: \.self) { option in
                    NovelReaderPageTurnDirectionButton(
                        direction: option,
                        isSelected: direction == option,
                        palette: palette
                    ) {
                        onSelect(option)
                    }
                }
            }
            .padding(6)
            .background(palette.segmentedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct NovelReaderPageTurnDirectionButton: View {
    let direction: ReaderPageTurnDirection
    let isSelected: Bool
    let palette: NovelReaderSheetPalette
    let action: () -> Void

    private var systemImageName: String {
        switch direction {
        case .leftToRight:
            "arrow.right"
        case .rightToLeft:
            "arrow.left"
        }
    }

    var body: some View {
        Button(action: action) {
            Label(direction.title, systemImage: systemImageName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isSelected ? Color.white : palette.primaryText)
                .background(
                    isSelected ? palette.confirmButtonBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction.title)
    }
}

private struct NovelReaderReadingModeButton: View {
    let option: NovelReaderReadingModeOption
    let isSelected: Bool
    let palette: NovelReaderSheetPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: option.systemImageName)
                    .font(.headline.weight(.semibold))
                    .frame(width: 24)

                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(isSelected ? Color.white : palette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                isSelected ? palette.confirmButtonBackground : palette.segmentedBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
    }
}

private enum NovelReaderReadingModeOption: CaseIterable, Hashable {
    case slide
    case pageCurl
    case quickFade
    case scroll

    init(_ settings: NovelReaderAppearanceSettings) {
        switch settings.readingMode {
        case .paged:
            switch settings.pagedTurnStyle {
            case .slide:
                self = .slide
            case .pageCurl:
                self = .pageCurl
            case .quickFade:
                self = .quickFade
            }
        case .vertical:
            self = .scroll
        }
    }

    var title: String {
        switch self {
        case .slide:
            L10n.string("reading_mode.slide")
        case .pageCurl:
            L10n.string("reading_mode.page_curl")
        case .quickFade:
            L10n.string("reading_mode.quick_fade")
        case .scroll:
            L10n.string("reading_mode.scroll")
        }
    }

    var systemImageName: String {
        switch self {
        case .slide:
            "arrow.left.to.line.square"
        case .pageCurl:
            "doc"
        case .quickFade:
            "bolt.square"
        case .scroll:
            "text.page"
        }
    }

    var readingMode: ReaderReadingMode {
        switch self {
        case .slide, .pageCurl, .quickFade:
            .paged
        case .scroll:
            .vertical
        }
    }

    var pagedTurnStyle: ReaderPagedTurnStyle? {
        switch self {
        case .slide:
            .slide
        case .pageCurl:
            .pageCurl
        case .quickFade:
            .quickFade
        case .scroll:
            nil
        }
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

struct NovelReaderDivider: View {
    let palette: NovelReaderSheetPalette

    var body: some View {
        Divider().overlay(palette.divider)
    }
}

#endif
