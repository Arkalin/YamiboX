import Foundation

/// Semantic navigation input. Argument parsing belongs to the app composition root.
public enum AppNavigationTarget: Hashable, Sendable {
    case tab(AppTab)
    case search
    case login
    case settings(SettingsSidebarDestination?)
    case mine(AppMineDestination)
    case favoriteUpdates
    case content(AppContentDestination, threadID: String)
    case forumURL(URL)

    var initialTab: AppTab {
        switch self {
        case let .tab(tab): tab
        case .login, .settings, .mine: .mine
        case .favoriteUpdates: .favorites
        case .search, .content, .forumURL: .forum
        }
    }
}

public enum AppMineDestination: String, Hashable, Sendable {
    case profile, messages, history, likes, downloads

    var requiresLogin: Bool { self == .profile || self == .messages }
}

public enum AppContentDestination: String, Hashable, Sendable {
    case normalThread = "normal"
    case novelDetail = "novel-detail"
    case mangaDetail = "manga-detail"
    case novelReader = "novel"
    case mangaReader = "manga"
}

struct MineNavigationRequest: Identifiable {
    enum Target {
        case login
        case settings(SettingsSidebarDestination?)
        case page(AppMineDestination)
    }
    let id = UUID()
    let target: Target
}
