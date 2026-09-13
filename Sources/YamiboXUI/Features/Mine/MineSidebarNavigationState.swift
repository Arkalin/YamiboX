import Observation
import SwiftUI
import YamiboXCore

enum MineSidebarSection: Hashable {
    case history, likes, settings

    var title: String {
        switch self {
        case .history: L10n.string("forum.history")
        case .likes: L10n.string("mine.my_likes")
        case .settings: L10n.string("settings.title")
        }
    }
}

enum MineSidebarDetail: Hashable {
    case profile, messages, downloads
    case history(BrowsingHistoryFilter)
    case likes(LikeWorkFilter)
    case settings(SettingsSidebarDestination)

    enum Identity: Hashable { case profile, messages, downloads, history, likes, settings }

    var identity: Identity {
        switch self {
        case .profile: .profile
        case .messages: .messages
        case .downloads: .downloads
        case .history: .history
        case .likes: .likes
        case .settings: .settings
        }
    }
}

/// Navigation belongs to this Mine window, independently of its detail stack.
@MainActor @Observable
final class MineSidebarNavigationState {
    private(set) var sidebarPath: [MineSidebarSection] = []
    private(set) var detail: MineSidebarDetail?
    var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    var isSelectingLikes = false

    var section: MineSidebarSection? { sidebarPath.last }

    func setSidebarPath(_ path: [MineSidebarSection]) {
        guard !isSelectingLikes else { return }
        guard let section = path.last else {
            returnToRoot()
            return
        }
        // Library filters live above their content, not in a pushed sidebar.
        if section == .history || section == .likes {
            guard sidebarPath.isEmpty else { return }
            show(section == .history ? .history(.all) : .likes(.all))
            return
        }
        guard sidebarPath != [section] else { return }
        sidebarPath = [section]
        switch section {
        case .history: detail = .history(.all)
        case .likes: detail = .likes(.all)
        case .settings: detail = .settings(.category(.general))
        }
        // A compact window first presents the submenu, not its default detail.
        preferredCompactColumn = .sidebar
    }

    func returnToRoot() {
        sidebarPath = []
        detail = nil
        isSelectingLikes = false
        preferredCompactColumn = .sidebar
    }

    func show(_ destination: MineSidebarDetail) {
        guard !isSelectingLikes else { return }
        switch destination {
        case .settings: guard section == .settings else { return }
        case .history, .likes, .profile, .messages, .downloads: guard section == nil else { return }
        }
        detail = destination
        preferredCompactColumn = .detail
    }

    func accountDidSignOut() {
        if detail == .profile || detail == .messages { returnToRoot() }
    }
}
