import SwiftUI
import YamiboXCore

public struct AppLaunchScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                (colorScheme == .dark ? Color.black : Color.white)
                    .ignoresSafeArea()

                HStack(spacing: 18) {
                    Image("LaunchIcon", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize(for: proxy.size), height: iconSize(for: proxy.size))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)

                    Text(L10n.string("app.name"))
                        .font(.system(size: titleSize(for: proxy.size), weight: .medium, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: proxy.size.width * 0.78)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.82)
            }
        }
    }

    private func iconSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.145, 46), 64)
    }

    private func titleSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.082, 26), 38)
    }
}
