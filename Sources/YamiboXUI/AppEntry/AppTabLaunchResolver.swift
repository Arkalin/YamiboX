import Foundation
import YamiboXCore

public enum AppTabLaunchResolver {
    public static func resolveInitialTab(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homePage: AppHomePage = .home
    ) -> AppTab {
        #if DEBUG
        switch environment["START_TAB"]?.lowercased() {
        case "home":
            return .home
        case "forum":
            return .forum
        case "favorites":
            return .favorites
        case "mine", "my", "migration":
            return .mine
        default:
            break
        }
        #endif

        switch homePage {
        case .home:
            return .home
        case .favorites:
            return .favorites
        case .forum:
            return .forum
        }
    }
}
