import SwiftUI
import YamiboXCore

/// Shared by startup and the settings preview, including actual text-area sampling.
struct AppLaunchBrandView: View {
    let settings: CustomBackgroundSettings
    let imageData: Data?
    var referenceSize: CGSize? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var titleRect = CGRect.zero
    @State private var contrast: (request: BackgroundContrastRequest, usesBlack: Bool)?

    var body: some View {
        GeometryReader { proxy in
            let request = BackgroundContrastRequest(imageData: settings.isEnabled ? imageData : nil,
                                                    settings: settings, containerSize: proxy.size, textRect: titleRect)
            let scale = proxy.size.width / max(1, referenceSize?.width ?? proxy.size.width)
            let designSize = referenceSize ?? proxy.size
            ZStack {
                HStack(spacing: 18 * scale) {
                    Image("LaunchIcon", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize(for: designSize) * scale, height: iconSize(for: designSize) * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
                        .accessibilityHidden(true)

                    Text(L10n.string("app.name"))
                        .font(.system(size: titleSize(for: designSize) * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(titleColor(for: request))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("launchBrandCanvas")) } action: { titleRect = $0 }
                }
                .frame(maxWidth: proxy.size.width * 0.78)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.82)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: "launchBrandCanvas")
            .task(id: request) {
                guard request.imageData != nil, !request.textRect.isEmpty else { return }
                if let usesBlack = await BackgroundTextContrast.shared.usesBlack(for: request), !Task.isCancelled {
                    contrast = (request, usesBlack)
                }
            }
        }
    }

    private func titleColor(for request: BackgroundContrastRequest) -> Color {
        if let contrast, contrast.request == request { return contrast.usesBlack ? .black : .white }
        return colorScheme == .dark ? .white : .black
    }

    private func iconSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.145, 46), 64)
    }

    private func titleSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.082, 26), 38)
    }
}
