import SwiftUI
import YamiboXCore

#if os(iOS)

protocol ReaderSettingsDirectionOption: Hashable, CaseIterable {
    var title: String { get }
}

extension MangaPageTurnDirection: ReaderSettingsDirectionOption {}
extension ReaderPageTurnDirection: ReaderSettingsDirectionOption {}

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
