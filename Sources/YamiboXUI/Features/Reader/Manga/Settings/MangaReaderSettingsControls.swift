import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsCardSection<Content: View>: View {
    let title: String
    let palette: MangaReaderSettingsPalette
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
                    .strokeBorder(palette.cardStroke, lineWidth: 1)
            }
        }
    }
}

struct MangaReaderBrightnessRow: View {
    @Binding var value: Double
    let palette: MangaReaderSettingsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(L10n.string("manga.brightness"))
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(palette.warmAccent)
                }
                .foregroundStyle(palette.primaryText)

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 14) {
                MangaReaderRoundIconButton(
                    systemName: "minus",
                    palette: palette
                ) {
                    value = max(0.25, value - 0.05)
                }

                Slider(value: $value, in: 0.25 ... 1.5, step: 0.05)
                    .tint(palette.warmAccent)

                MangaReaderRoundIconButton(
                    systemName: "plus",
                    palette: palette
                ) {
                    value = min(1.5, value + 0.05)
                }
            }
        }
    }
}

private struct MangaReaderRoundIconButton: View {
    let systemName: String
    let palette: MangaReaderSettingsPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 42, height: 42)
                .background(palette.segmentedBackground, in: Circle())
                .expandedHitTarget()
        }
        .buttonStyle(.plain)
    }
}

struct MangaReaderSettingsToggleRow: View {
    let title: String
    let palette: MangaReaderSettingsPalette
    var statusText: String?
    var isEnabled = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                if let statusText {
                    Text(statusText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.62)
    }
}

struct MangaReaderModePicker: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var selectedMode: MangaReaderSettingsModeOption {
        MangaReaderSettingsModeOption(settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reading_mode.title"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(MangaReaderSettingsModeOption.allCases, id: \.self) { option in
                    MangaReaderModeButton(
                        option: option,
                        isSelected: selectedMode == option,
                        palette: palette
                    ) {
                        settings.selectMode(option)
                    }
                }
            }
        }
    }
}

private struct MangaReaderModeButton: View {
    let option: MangaReaderSettingsModeOption
    let isSelected: Bool
    let palette: MangaReaderSettingsPalette
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
            .foregroundStyle(isSelected ? palette.selectedControlText : palette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                isSelected ? palette.selectedControlBackground : palette.segmentedBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MangaReaderDirectionPicker: View {
    @Binding var direction: MangaPageTurnDirection
    let palette: MangaReaderSettingsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("manga.page_turn_direction"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 8) {
                ForEach(MangaPageTurnDirection.allCases, id: \.self) { option in
                    MangaReaderDirectionButton(
                        direction: option,
                        isSelected: direction == option,
                        palette: palette
                    ) {
                        direction = option
                    }
                }
            }
            .padding(6)
            .background(palette.segmentedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private struct MangaReaderDirectionButton: View {
    let direction: MangaPageTurnDirection
    let isSelected: Bool
    let palette: MangaReaderSettingsPalette
    let action: () -> Void

    private var systemImageName: String {
        switch direction {
        case .rightToLeft:
            "arrow.left"
        case .leftToRight:
            "arrow.right"
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
                .foregroundStyle(isSelected ? palette.selectedControlText : palette.primaryText)
                .background(
                    isSelected ? palette.selectedControlBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

struct MangaReaderPageScaleModeMenuRow: View {
    @Binding var scaleMode: MangaPageScaleMode
    let palette: MangaReaderSettingsPalette

    var body: some View {
        Menu {
            Picker(
                L10n.string("manga.page_scale_mode"),
                selection: $scaleMode
            ) {
                ForEach(MangaPageScaleMode.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.systemImageName)
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(L10n.string("manga.page_scale_mode"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Text(scaleMode.title)
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.75))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MangaReaderPageEdgeFillMenuRow: View {
    @Binding var edgeFillStyle: MangaPageEdgeFillStyle
    let palette: MangaReaderSettingsPalette

    var body: some View {
        Menu {
            Picker(
                L10n.string("manga.page_edge_fill"),
                selection: $edgeFillStyle
            ) {
                ForEach(MangaPageEdgeFillStyle.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.systemImageName)
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(L10n.string("manga.page_edge_fill"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Text(edgeFillStyle.title)
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.75))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MangaReaderSettingsDivider: View {
    let palette: MangaReaderSettingsPalette

    var body: some View {
        Divider().overlay(palette.divider)
    }
}

enum MangaReaderSettingsModeOption: CaseIterable, Hashable {
    case slide
    case pageCurl
    case quickFade
    case scroll

    init(_ settings: MangaReaderSettings) {
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

extension MangaPageScaleMode {
    var systemImageName: String {
        switch self {
        case .fitHeight:
            "arrow.up.and.down"
        case .fitWidth:
            "arrow.left.and.right"
        }
    }
}

extension MangaPageEdgeFillStyle {
    var systemImageName: String {
        switch self {
        case .white:
            "circle"
        case .black:
            "circle.fill"
        case .system:
            "circle.lefthalf.filled"
        }
    }

    func settingsPreviewColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .white:
            Color.white
        case .black:
            Color.black
        case .system:
            colorScheme == .dark ? Color.black : Color.white
        }
    }
}

extension MangaReaderSettings {
    var usesPagedMode: Bool {
        readingMode == .paged
    }

    mutating func selectMode(_ option: MangaReaderSettingsModeOption) {
        if let pagedTurnStyle = option.pagedTurnStyle {
            readingMode = .paged
            self.pagedTurnStyle = pagedTurnStyle
        } else {
            readingMode = .vertical
        }
    }
}
#endif
