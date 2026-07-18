import SwiftUI

#if os(iOS)

/// Titled card container used by every section of both reader settings
/// sheets. Replaces `MangaReaderSettingsCardSection` and
/// `NovelReaderSettingsSection`, whose layout constants were identical
/// (spacing 14/16, padding 20, corner radius 26 continuous, 1pt stroke);
/// only the stroke color differed, which `Palette.sectionStroke` carries.
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

/// Row divider tinted with the palette hairline; replaces
/// `MangaReaderSettingsDivider` and `NovelReaderDivider` (identical bodies).
struct ReaderSettingsDivider<Palette: ReaderSettingsPalette>: View {
    let palette: Palette

    var body: some View {
        Divider().overlay(palette.divider)
    }
}

#endif
