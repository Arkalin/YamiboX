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
}

extension MangaPageTurnDirection: ReaderSettingsDirectionOption {}
extension ReaderPageTurnDirection: ReaderSettingsDirectionOption {}

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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.secondaryText)

            ReaderSettingsSegmentedControl(palette: palette) {
                ForEach(Direction.allCases, id: \.self) { option in
                    ReaderSettingsSegmentButton(
                        title: option.title,
                        isSelected: selection == option,
                        palette: palette
                    ) {
                        onSelect(option)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }
}

#endif
