import Foundation

public enum AppHomePage: String, Codable, Hashable, CaseIterable, Sendable {
    case favorites
    case forum

    public var title: String {
        switch self {
        case .favorites: L10n.string("app.home.favorites")
        case .forum: L10n.string("app.home.forum")
        }
    }

    public var systemImageName: String {
        switch self {
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
    public var usesDataSaverMode: Bool
    public var applePencilPageTurn: ApplePencilPageTurnSettings
    public var gamepad: GamepadSettings
    public var keyboard: KeyboardSettings

    public init(
        homePage: AppHomePage = .forum,
        usesDataSaverMode: Bool = false,
        applePencilPageTurn: ApplePencilPageTurnSettings = .init(),
        gamepad: GamepadSettings = .init(),
        keyboard: KeyboardSettings = .init()
    ) {
        self.homePage = homePage
        self.usesDataSaverMode = usesDataSaverMode
        self.applePencilPageTurn = applePencilPageTurn
        self.gamepad = gamepad
        self.keyboard = keyboard
    }
}
