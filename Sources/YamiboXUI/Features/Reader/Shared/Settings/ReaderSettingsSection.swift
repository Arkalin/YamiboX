import SwiftUI

#if os(iOS)

struct ReaderSettingsSection<Palette: ReaderSettingsPalette, Content: View>: View {
    let title: String
    let palette: Palette
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
                    .strokeBorder(palette.sectionStroke, lineWidth: 1)
            }
        }
    }
}

struct ReaderSettingsDivider<Palette: ReaderSettingsPalette>: View {
    let palette: Palette

    var body: some View {
        Divider().overlay(palette.divider)
    }
}

#endif
