import Foundation

/// Legacy startup-page values retained only for local and WebDAV compatibility.
public enum AppHomePage: String, Codable, Hashable, CaseIterable, Sendable {
    case home
    case favorites
    case forum

    public var tab: AppTab {
        switch self {
        case .home: .bookshelf
        case .favorites: .favorites
        case .forum: .forum
        }
    }

    public init(tab: AppTab) {
        switch tab {
        case .bookshelf: self = .home
        case .favorites: self = .favorites
        default: self = .forum
        }
    }

}

public enum ApplePencilPageTurnGesture: Hashable, Sendable {
    case doubleTap
    case squeeze
}

public enum ApplePencilPageTurnBehavior: String, Codable, Hashable, CaseIterable, Sendable {
    case doubleTapPreviousSqueezeNext
    case doubleTapNextSqueezePrevious

    public var title: String {
        switch self {
        case .doubleTapPreviousSqueezeNext: L10n.string("apple_pencil.behavior.double_tap_previous_squeeze_next")
        case .doubleTapNextSqueezePrevious: L10n.string("apple_pencil.behavior.double_tap_next_squeeze_previous")
        }
    }

    public var doubleTapPageDelta: Int {
        pageDelta(for: .doubleTap)
    }

    public var squeezePageDelta: Int {
        pageDelta(for: .squeeze)
    }

    public func pageDelta(for gesture: ApplePencilPageTurnGesture) -> Int {
        switch (self, gesture) {
        case (.doubleTapPreviousSqueezeNext, .doubleTap),
             (.doubleTapNextSqueezePrevious, .squeeze):
            -1
        case (.doubleTapPreviousSqueezeNext, .squeeze),
             (.doubleTapNextSqueezePrevious, .doubleTap):
            1
        }
    }
}

public struct ApplePencilPageTurnSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var behavior: ApplePencilPageTurnBehavior

    public init(
        isEnabled: Bool = false,
        behavior: ApplePencilPageTurnBehavior = .doubleTapPreviousSqueezeNext
    ) {
        self.isEnabled = isEnabled
        self.behavior = behavior
    }
}

public struct SystemSettings: Codable, Hashable, Sendable {
    public var navigation: AppNavigationSettings
    /// Compatibility projection for settings snapshots written by older clients.
    public var homePage: AppHomePage { AppHomePage(tab: navigation.startupTab) }
    public var homeShowsOnlyFavorites: Bool
    public var usesDataSaverMode: Bool
    public var enhancedCheckInEnabled: Bool
    public var applePencilPageTurn: ApplePencilPageTurnSettings
    public var gamepad: GamepadSettings
    public var keyboard: KeyboardSettings

    public init(
        homePage: AppHomePage = .home,
        navigation: AppNavigationSettings? = nil,
        homeShowsOnlyFavorites: Bool = false,
        usesDataSaverMode: Bool = false,
        enhancedCheckInEnabled: Bool = false,
        applePencilPageTurn: ApplePencilPageTurnSettings = .init(),
        gamepad: GamepadSettings = .init(),
        keyboard: KeyboardSettings = .init()
    ) {
        self.navigation = navigation ?? AppNavigationSettings(startupTab: homePage.tab)
        self.homeShowsOnlyFavorites = homeShowsOnlyFavorites
        self.usesDataSaverMode = usesDataSaverMode
        self.enhancedCheckInEnabled = enhancedCheckInEnabled
        self.applePencilPageTurn = applePencilPageTurn
        self.gamepad = gamepad
        self.keyboard = keyboard
    }

    private enum CodingKeys: String, CodingKey {
        case homePage
        case navigation
        case homeShowsOnlyFavorites
        case usesDataSaverMode
        case enhancedCheckInEnabled
        case applePencilPageTurn
        case gamepad
        case keyboard
    }

    /// Decode newer preferences optionally so existing settings retain every other value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            homePage: try container.decodeIfPresent(AppHomePage.self, forKey: .homePage) ?? .forum,
            navigation: try container.decodeIfPresent(AppNavigationSettings.self, forKey: .navigation),
            homeShowsOnlyFavorites: try container.decodeIfPresent(Bool.self, forKey: .homeShowsOnlyFavorites) ?? false,
            usesDataSaverMode: try container.decodeIfPresent(Bool.self, forKey: .usesDataSaverMode) ?? false,
            enhancedCheckInEnabled: try container.decodeIfPresent(Bool.self, forKey: .enhancedCheckInEnabled) ?? false,
            applePencilPageTurn: try container.decodeIfPresent(ApplePencilPageTurnSettings.self, forKey: .applePencilPageTurn) ?? .init(),
            gamepad: try container.decodeIfPresent(GamepadSettings.self, forKey: .gamepad) ?? .init(),
            keyboard: try container.decodeIfPresent(KeyboardSettings.self, forKey: .keyboard) ?? .init()
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(homePage, forKey: .homePage)
        try container.encode(navigation, forKey: .navigation)
        try container.encode(homeShowsOnlyFavorites, forKey: .homeShowsOnlyFavorites)
        try container.encode(usesDataSaverMode, forKey: .usesDataSaverMode)
        try container.encode(enhancedCheckInEnabled, forKey: .enhancedCheckInEnabled)
        try container.encode(applePencilPageTurn, forKey: .applePencilPageTurn)
        try container.encode(gamepad, forKey: .gamepad)
        try container.encode(keyboard, forKey: .keyboard)
    }
}
