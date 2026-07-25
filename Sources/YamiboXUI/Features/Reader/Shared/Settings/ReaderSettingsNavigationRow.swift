import SwiftUI

#if os(iOS)

/// Title + trailing chevron row that opens another screen instead of editing
/// a value in place. Layout matches ``ReaderSettingsToggleRow`` (its neighbor
/// in both readers' "Other" section) so the two line up inside one card.
struct ReaderSettingsNavigationRow<Palette: ReaderSettingsPalette>: View {
    let title: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.75))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif
