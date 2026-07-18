import SwiftUI
import YamiboXCore

#if os(iOS)

/// A page-turn direction the shared picker can present.
///
/// Manga and Novel keep distinct core enums (`MangaPageTurnDirection` /
/// `ReaderPageTurnDirection`) whose `allCases` order — and therefore the
/// on-screen button order — intentionally differs (Manga leads with
/// right-to-left, Novel with left-to-right). The picker is generic so each
/// side keeps its own type and ordering.
protocol ReaderSettingsDirectionOption: Hashable, CaseIterable {
    var title: String { get }
    var settingsIconSystemImageName: String { get }
}

// Both readers use the same arrow glyph for the same semantic direction, so
// the two conformances live together here rather than one per feature.
extension MangaPageTurnDirection: ReaderSettingsDirectionOption {
    var settingsIconSystemImageName: String {
        switch self {
        case .rightToLeft: "arrow.left"
        case .leftToRight: "arrow.right"
        }
    }
}

extension ReaderPageTurnDirection: ReaderSettingsDirectionOption {
    var settingsIconSystemImageName: String {
        switch self {
        case .leftToRight: "arrow.right"
        case .rightToLeft: "arrow.left"
        }
    }
}

/// Segmented page-turn direction control; replaces
/// `MangaReaderDirectionPicker` and `NovelReaderPageTurnDirectionPicker`.
/// The heading is a parameter because the readers use different L10n keys
/// ("manga.page_turn_direction" vs "reader.page_turn_direction").
struct ReaderSettingsDirectionPicker<Direction: ReaderSettingsDirectionOption, Palette: ReaderSettingsPalette>: View
    where Direction.AllCases: RandomAccessCollection
{
    let title: String
    let selection: Direction
    let palette: Palette
    let onSelect: (Direction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            HStack(spacing: 8) {
                ForEach(Direction.allCases, id: \.self) { option in
                    ReaderSettingsDirectionButton(
                        direction: option,
                        isSelected: selection == option,
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

private struct ReaderSettingsDirectionButton<Direction: ReaderSettingsDirectionOption, Palette: ReaderSettingsPalette>: View {
    let direction: Direction
    let isSelected: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(direction.title, systemImage: direction.settingsIconSystemImageName)
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
        // Carried over from Novel's original button; invisible and equally
        // valid for Manga.
        .accessibilityLabel(direction.title)
    }
}

#endif
