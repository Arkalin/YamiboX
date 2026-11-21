import SwiftUI

#if os(iOS)

struct ReaderSettingsStepperButton<Palette: ReaderSettingsPalette>: View {
    let systemName: String
    let palette: Palette
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: diameter, height: diameter)
                .background(palette.segmentedBackground, in: Circle())
                .expandedHitTarget()
        }
        .buttonStyle(.plain)
    }
}

#endif
