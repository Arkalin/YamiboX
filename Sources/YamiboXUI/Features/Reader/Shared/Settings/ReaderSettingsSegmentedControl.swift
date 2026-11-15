import SwiftUI

#if os(iOS)

struct ReaderSettingsSegmentedControl<Palette: ReaderSettingsPalette, Content: View>: View {
    let palette: Palette
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(4)
        .background(palette.segmentedBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ReaderSettingsSegmentButton<Palette: ReaderSettingsPalette>: View {
    let title: String
    let isSelected: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isSelected ? palette.selectedControlText : palette.primaryText)
            .background(
                isSelected ? palette.selectedControlBackground : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#endif
