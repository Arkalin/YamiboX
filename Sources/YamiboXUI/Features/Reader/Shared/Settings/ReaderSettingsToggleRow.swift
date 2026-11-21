import SwiftUI

#if os(iOS)

struct ReaderSettingsToggleRow<Palette: ReaderSettingsPalette>: View {
    let title: String
    let palette: Palette
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title3)
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            AppThemeSwitch(title, isOn: $isOn)
                .labelsHidden()
        }
    }
}

#endif
