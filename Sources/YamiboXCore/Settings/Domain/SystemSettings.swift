import Foundation

public enum AppHomePage: String, Codable, Hashable, CaseIterable, Sendable {
    case home
    case favorites
    case forum

    public var title: String {
        switch self {
        case .home: L10n.string("tab.home")
        case .favorites: L10n.string("app.home.favorites")
        case .forum: L10n.string("app.home.forum")
        }
    }

    public var systemImageName: String {
        switch self {
        case .home: "house"
        case .favorites: "heart.text.square"
        case .forum: "text.bubble"
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
    public var homePage: AppHomePage
    public var homeShowsOnlyFavorites: Bool
    public var usesDataSaverMode: Bool
    public var enhancedCheckInEnabled: Bool
    public var applePencilPageTurn: ApplePencilPageTurnSettings
    public var gamepad: GamepadSettings
    public var keyboard: KeyboardSettings

    public init(
        homePage: AppHomePage = .home,
        homeShowsOnlyFavorites: Bool = false,
        usesDataSaverMode: Bool = false,
        enhancedCheckInEnabled: Bool = false,
        applePencilPageTurn: ApplePencilPageTurnSettings = .init(),
        gamepad: GamepadSettings = .init(),
        keyboard: KeyboardSettings = .init()
    ) {
        self.homePage = homePage
        self.homeShowsOnlyFavorites = homeShowsOnlyFavorites
        self.usesDataSaverMode = usesDataSaverMode
        self.enhancedCheckInEnabled = enhancedCheckInEnabled
        self.applePencilPageTurn = applePencilPageTurn
        self.gamepad = gamepad
        self.keyboard = keyboard
    }

    private enum CodingKeys: String, CodingKey {
        case homePage
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
            homeShowsOnlyFavorites: try container.decodeIfPresent(Bool.self, forKey: .homeShowsOnlyFavorites) ?? false,
            usesDataSaverMode: try container.decodeIfPresent(Bool.self, forKey: .usesDataSaverMode) ?? false,
            enhancedCheckInEnabled: try container.decodeIfPresent(Bool.self, forKey: .enhancedCheckInEnabled) ?? false,
            applePencilPageTurn: try container.decodeIfPresent(ApplePencilPageTurnSettings.self, forKey: .applePencilPageTurn) ?? .init(),
            gamepad: try container.decodeIfPresent(GamepadSettings.self, forKey: .gamepad) ?? .init(),
            keyboard: try container.decodeIfPresent(KeyboardSettings.self, forKey: .keyboard) ?? .init()
        )
    }
}
