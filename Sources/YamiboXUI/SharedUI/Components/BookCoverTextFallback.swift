import SwiftUI

/// Shared title-on-color cover for favorites and book detail pages.
/// The caller supplies the cover's frame; title-length font steps scale with
/// its width so list thumbnails and larger covers retain the same proportions.
struct BookCoverTextFallback: View {
    let title: String
    let boxWidth: CGFloat
    @Environment(\.appTheme) private var appTheme

    /// Reference cover width for the Android-compatible 32/24/19/15/12 font steps.
    private static let referenceWidth: CGFloat = 150

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(appTheme.controlAccent.opacity(0.12))
            Text(trimmedTitle)
                .font(.system(size: fontSize, weight: .bold))
                .lineSpacing(fontSize * 0.15)
                .foregroundStyle(appTheme.controlAccent.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(scaledPadding)
        }
        .clipped()
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var scale: CGFloat {
        guard boxWidth.isFinite, boxWidth > 0 else { return 1 }
        return boxWidth / Self.referenceWidth
    }

    private var scaledPadding: CGFloat {
        max(2, 8 * scale)
    }

    private var fontSize: CGFloat {
        // 10pt floor: below that the title stops being legible at all and the
        // tile reads as noise (small mosaic tiles used to bottom out at 6pt).
        max(10, baseFontSize * scale)
    }

    private var baseFontSize: CGFloat {
        switch trimmedTitle.count {
        case ...6: 32
        case ...12: 24
        case ...24: 19
        case ...40: 15
        default: 12
        }
    }
}
