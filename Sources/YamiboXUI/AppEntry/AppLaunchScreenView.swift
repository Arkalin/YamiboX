import SwiftUI
import YamiboXCore

public struct AppLaunchScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.launchBackgroundState) private var background

    public init() {}

    public var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea()
            CustomBackgroundLayer(settings: background?.settings ?? .init(), imageData: background?.imageData)
                .ignoresSafeArea()
            if background?.showsOverlay ?? true {
                AppLaunchBrandView(settings: background?.settings ?? .init(), imageData: background?.imageData)
            }
        }
        .ignoresSafeArea()
    }
}

extension EnvironmentValues {
    @Entry public var launchBackgroundState: CustomBackgroundState? = nil
}
