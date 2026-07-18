import SwiftUI
import YamiboXCore

#if os(iOS)

// The section card, divider, toggle row, mode/direction pickers, and the
// round stepper button are shared with the Novel sheet — see
// Reader/Shared/Settings. This file keeps only the Manga-specific rows and
// the mappings between Manga settings and the shared option types.

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
                // 42pt is the Manga sheet's original size; Novel uses 44pt.
                ReaderSettingsStepperButton(
                    systemName: "minus",
                    palette: palette,
                    diameter: 42
                ) {
                    value = max(0.25, value - 0.05)
                }

                Slider(value: $value, in: 0.25 ... 1.5, step: 0.05)
                    .tint(palette.warmAccent)

                ReaderSettingsStepperButton(
                    systemName: "plus",
                    palette: palette,
                    diameter: 42
                ) {
                    value = min(1.5, value + 0.05)
                }
            }
        }
    }
}

/// An enum the Manga dropdown row can present. The page-scale and edge-fill
/// rows were verbatim copies differing only in the option type and title
/// key, so one generic row serves both.
protocol MangaReaderSettingsMenuOption: Hashable, CaseIterable {
    var title: String { get }
    var systemImageName: String { get }
}

extension MangaPageScaleMode: MangaReaderSettingsMenuOption {}
extension MangaPageEdgeFillStyle: MangaReaderSettingsMenuOption {}

/// Dropdown row (page scale mode / page edge fill). Manga-only: the Novel
/// sheet's menu row (`NovelReaderFontPickerRow`) has a different layout, so
/// this deliberately stays on the Manga side.
struct MangaReaderSettingsMenuRow<Option: MangaReaderSettingsMenuOption>: View
    where Option.AllCases: RandomAccessCollection
{
    let title: String
    @Binding var selection: Option
    let palette: MangaReaderSettingsPalette

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(Option.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.systemImageName)
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Text(selection.title)
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

extension ReaderSettingsReadingModeOption {
    /// Maps Manga settings onto the shared option; Novel keeps the same
    /// shape of initializer next to its own settings type.
    init(_ settings: MangaReaderSettings) {
        self.init(
            isPaged: settings.readingMode == .paged,
            pagedTurnStyle: settings.pagedTurnStyle
        )
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

    mutating func selectMode(_ option: ReaderSettingsReadingModeOption) {
        if let pagedTurnStyle = option.pagedTurnStyle {
            readingMode = .paged
            self.pagedTurnStyle = pagedTurnStyle
        } else {
            readingMode = .vertical
        }
    }
}
#endif
