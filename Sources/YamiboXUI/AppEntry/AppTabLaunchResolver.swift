import Foundation
import YamiboXCore

public enum AppTabLaunchResolver {
    public static func resolveInitialTab(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homePage: AppHomePage = .forum
    ) -> AppTab {
        #if DEBUG
        switch environment["START_TAB"]?.lowercased() {
        case "favorites":
            return .favorites
        case "mine", "my", "migration":
            return .mine
        default:
            break
        }
        #endif

        switch homePage {
        case .favorites:
            return .favorites
        case .forum:
            return .forum
        }
    }
}
