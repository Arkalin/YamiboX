import SwiftUI

#if os(iOS)

struct ReaderSettingsNavigationRow<Palette: ReaderSettingsPalette>: View {
    let title: String
    let palette: Palette
    var value: String? = nil
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

                if let value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.75))
            }
            .frame(minHeight: value == nil ? nil : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(value ?? "")
    }
}

#endif
