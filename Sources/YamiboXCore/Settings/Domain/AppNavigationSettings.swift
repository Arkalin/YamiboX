import Foundation

public enum AppTab: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case bookshelf, forum, favorites, mine, messages, history, likes

    public var id: String { rawValue }
    public var isRequired: Bool { [.forum, .favorites, .mine].contains(self) }

    public static func named(_ value: String) -> AppTab? {
        value == "home" ? .bookshelf : AppTab(rawValue: value)
    }
}

public struct AppNavigationSettings: Codable, Hashable, Sendable {
    public private(set) var tabs: [AppTab]
    public private(set) var startupTab: AppTab

    public init(tabs: [AppTab] = [.bookshelf, .forum, .favorites, .mine], startupTab: AppTab = .bookshelf) {
        var seen = Set<AppTab>()
        var optionalCount = 0
        var result = tabs.filter { tab in
            guard seen.insert(tab).inserted else { return false }
            if !tab.isRequired {
                optionalCount += 1
                return optionalCount <= 2
            }
            return true
        }
        for tab in [AppTab.forum, .favorites, .mine] where !result.contains(tab) {
            result.append(tab)
        }
        self.tabs = result
        self.startupTab = result.contains(startupTab) ? startupTab : result[0]
    }

    public var unreadIndicatorTab: AppTab { tabs.contains(.messages) ? .messages : .mine }

    private enum CodingKeys: String, CodingKey { case tabs, startupTab }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try? container.decode([String].self, forKey: .tabs)
        let startup = try? container.decode(String.self, forKey: .startupTab)
        let normalized = Self(tabs: names.map { $0.compactMap(AppTab.named) } ?? Self().tabs)
        self.init(
            tabs: normalized.tabs,
            startupTab: startup.flatMap(AppTab.named) ?? normalized.tabs[0]
        )
    }
}
