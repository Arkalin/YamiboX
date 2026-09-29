import Foundation
import YamiboXCore

public enum AppTabLaunchResolver {
    public static func resolveInitialTab(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        navigation: AppNavigationSettings = .init()
    ) -> AppTab {
        #if DEBUG
        if let name = environment["START_TAB"]?.lowercased(),
           let tab = AppTab.named(name == "my" || name == "migration" ? "mine" : name),
           navigation.tabs.contains(tab) {
            return tab
        }
        #endif

        return navigation.startupTab
    }
}
