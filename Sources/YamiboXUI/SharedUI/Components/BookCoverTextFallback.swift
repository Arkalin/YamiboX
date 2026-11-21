import SwiftUI

struct BookCoverTextFallback: View {
    let title: String
    let boxWidth: CGFloat
    @Environment(\.appTheme) private var appTheme

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
