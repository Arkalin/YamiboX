import SwiftUI
import YamiboXCore

#if os(iOS)

enum ReaderSettingsReadingModeOption: String, CaseIterable, Hashable {
    case paged
    case scroll

    init(isPaged: Bool) {
        self = isPaged ? .paged : .scroll
    }

    var title: String {
        switch self {
        case .paged: L10n.string("reading_mode.page_turn")
        case .scroll: L10n.string("reading_mode.scroll")
        }
    }

    var readingMode: ReaderReadingMode {
        self == .paged ? .paged : .vertical
    }
}

struct ReaderSettingsModePicker<Palette: ReaderSettingsPalette>: View {
    let selection: ReaderSettingsReadingModeOption
    let pagedTurnStyle: ReaderPagedTurnStyle
    let palette: Palette
    let onSelect: (ReaderSettingsReadingModeOption) -> Void
    let onSelectAnimation: (ReaderPagedTurnStyle) -> Void

    @ScaledMetric(relativeTo: .body) private var animationIconWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reading_mode.title"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            ReaderSettingsSegmentedControl(palette: palette) {
                ForEach(ReaderSettingsReadingModeOption.allCases, id: \.self) { option in
                    ReaderSettingsSegmentButton(
                        title: option.title,
                        isSelected: selection == option,
                        palette: palette
                    ) {
                        onSelect(option)
                    }
                    .accessibilityIdentifier("reader.settings.mode.\(option.rawValue)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("reading_mode.title"))

            if selection == .paged {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("reading_mode.animation"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.top, 4)
                        .padding(.bottom, 2)

                    ForEach(ReaderPagedTurnStyle.allCases, id: \.self) { style in
                        ReaderSettingsAnimationRow(
                            style: style,
                            isSelected: pagedTurnStyle == style,
                            iconWidth: min(animationIconWidth, 34),
                            palette: palette
                        ) {
                            onSelectAnimation(style)
                        }
                        if style != ReaderPagedTurnStyle.allCases.last {
                            ReaderSettingsDivider(palette: palette)
                                .padding(.leading, min(animationIconWidth, 34) + 16)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.string("reading_mode.animation"))
            }
        }
    }
}

private struct ReaderSettingsAnimationRow<Palette: ReaderSettingsPalette>: View {
    let style: ReaderPagedTurnStyle
    let isSelected: Bool
    let iconWidth: CGFloat
    let palette: Palette
    let action: () -> Void

    private var systemImage: String {
        switch style {
        case .none: "rectangle"
        case .slide: "arrow.left.and.right"
        case .pageCurl: "doc"
        case .quickFade: "square.on.square"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: iconWidth)
                    .foregroundStyle(isSelected ? palette.selectedControlBackground : palette.secondaryText)
                Text(style.title)
                    .font(.body)
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(palette.selectedControlBackground)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: iconWidth)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("reader.settings.animation.\(style.rawValue)")
    }
}

#endif
