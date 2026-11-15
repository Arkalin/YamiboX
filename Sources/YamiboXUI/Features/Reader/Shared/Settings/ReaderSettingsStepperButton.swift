import SwiftUI

#if os(iOS)

/// Circular +/- button flanking the settings sliders. Replaces Manga's
/// private `MangaReaderRoundIconButton` and Novel's private `circleButton`
/// helper, which were identical except for the control size.
///
/// The diameter is a required parameter because the two sheets genuinely
/// differ: Manga draws the button at 42pt, Novel at 44pt. Keeping it explicit
/// at each call site preserves both original values.
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
                // Manga's original: brings the 42pt variant up to the 44pt
                // HIG hit floor without growing the layout. At 44pt this is
                // geometrically a no-op, so it is safe on the Novel sheet too.
                .expandedHitTarget()
        }
        .buttonStyle(.plain)
    }
}

#endif
