import Foundation

/// Logical reader actions a game controller can trigger. The raw values are
/// persisted inside ``GamepadSettings/bindings``.
public enum ReaderControlAction: String, Codable, Hashable, CaseIterable, Sendable {
    case nextPage
    case previousPage
    case openComments
    case toggleChrome

    /// The Menu button is hard-wired to ``toggleChrome`` so a controller can
    /// always summon the chrome; it never appears in the bindings table.
    public var isUserBindable: Bool {
        self != .toggleChrome
    }

    public static var userBindableActions: [ReaderControlAction] {
        allCases.filter(\.isUserBindable)
    }

    public var title: String {
        switch self {
        case .nextPage: L10n.string("settings.gamepad.next_page")
        case .previousPage: L10n.string("settings.gamepad.previous_page")
        case .openComments: L10n.string("settings.gamepad.open_comments")
        case .toggleChrome: L10n.string("settings.gamepad.toggle_chrome")
        }
    }
}

/// Stable GameController element alias strings (`GCInput*` constants). Kept as
/// plain strings so the settings layer stays free of GameController imports;
/// the UI glue matches them against `GCPhysicalInputElement.aliases`.
public enum GamepadElementAlias {
    public static let buttonA = "Button A"
    public static let buttonB = "Button B"
    public static let buttonX = "Button X"
    public static let buttonY = "Button Y"
    public static let leftShoulder = "Left Shoulder"
    public static let rightShoulder = "Right Shoulder"
    public static let leftTrigger = "Left Trigger"
    public static let rightTrigger = "Right Trigger"
    public static let buttonOptions = "Button Options"
    public static let buttonMenu = "Button Menu"
    public static let buttonHome = "Button Home"
    public static let leftThumbstickButton = "Left Thumbstick Button"
    public static let rightThumbstickButton = "Right Thumbstick Button"
    public static let directionPad = "Direction Pad"

    /// Elements a user may bind in the capture UI, in canonical preference
    /// order. The direction pad and Menu carry fixed semantics, Home is
    /// intercepted by the system, and analog elements never qualify.
    public static let bindableAliasPriority: [String] = [
        buttonA, buttonB, buttonX, buttonY,
        leftShoulder, rightShoulder,
        leftTrigger, rightTrigger,
        buttonOptions,
        leftThumbstickButton, rightThumbstickButton,
    ]

    public static let userBindableAliases = Set(bindableAliasPriority)

    public static func isUserBindable<Aliases: Sequence<String>>(anyOf aliases: Aliases) -> Bool {
        aliases.contains(where: userBindableAliases.contains)
    }

    /// Picks the stable alias to persist when an element advertises several
    /// (live-input elements report a whole alias set at once).
    public static func canonicalBindableAlias<Aliases: Collection<String>>(in aliases: Aliases) -> String? {
        bindableAliasPriority.first(where: aliases.contains)
    }
}

public struct GamepadSettings: Codable, Hashable, Sendable {
    /// Master switch. Gates action dispatch inside the readers only; the
    /// settings page keeps capturing and showing connection state regardless.
    public var isEnabled: Bool

    /// Maps user-bindable actions to a GameController element alias. Menu and
    /// the direction pad are fixed in code and never stored here. An absent
    /// key means the action is unbound.
    public var bindings: [ReaderControlAction: String]

    public init(
        isEnabled: Bool = true,
        bindings: [ReaderControlAction: String] = Self.defaultBindings
    ) {
        self.isEnabled = isEnabled
        self.bindings = bindings
    }

    /// Defaults follow physical positions (bottom/left/top face button); the
    /// UI renders per-controller glyphs so Nintendo-labelled pads stay honest.
    public static let defaultBindings: [ReaderControlAction: String] = [
        .nextPage: GamepadElementAlias.buttonA,
        .previousPage: GamepadElementAlias.buttonX,
        .openComments: GamepadElementAlias.buttonY,
    ]

    public func action(boundToAnyOf aliases: Set<String>) -> ReaderControlAction? {
        bindings.first { action, alias in
            action.isUserBindable && aliases.contains(alias)
        }?.key
    }

    /// Binds `action` to `alias`, stealing the alias from any action that
    /// currently holds it (last write wins; the losing action becomes unbound).
    public mutating func bind(_ action: ReaderControlAction, toElementAlias alias: String) {
        guard action.isUserBindable else { return }
        for (existingAction, existingAlias) in bindings where existingAlias == alias {
            bindings.removeValue(forKey: existingAction)
        }
        bindings[action] = alias
    }

    public mutating func clearBinding(for action: ReaderControlAction) {
        bindings.removeValue(forKey: action)
    }

    public mutating func restoreDefaultBindings() {
        bindings = Self.defaultBindings
    }
}

/// Stable USB HID keyboard usage IDs ("Keyboard/Keypad Page 0x07" of the USB
/// HID Usage Tables) — the same raw values GameController's `GCKeyCode.rawValue`
/// reports. Kept as plain Int constants so the settings layer stays free of
/// GameController imports, mirroring ``GamepadElementAlias``.
public enum KeyboardKeyCode {
    public static let escape = 0x29
    public static let tab = 0x2B
    public static let capsLock = 0x39
    public static let leftControl = 0xE0
    public static let leftShift = 0xE1
    public static let leftAlt = 0xE2
    public static let leftGUI = 0xE3
    public static let rightControl = 0xE4
    public static let rightShift = 0xE5
    public static let rightAlt = 0xE6
    public static let rightGUI = 0xE7
    public static let upArrow = 0x52
    public static let downArrow = 0x51
    public static let leftArrow = 0x50
    public static let rightArrow = 0x4F
    public static let spacebar = 0x2C
    public static let deleteOrBackspace = 0x2A
    public static let keyC = 0x06

    /// The arrow keys carry fixed directional semantics, like the gamepad's
    /// direction pad; they never appear in ``KeyboardSettings/bindings``.
    public static let fixedDirectionCodes: Set<Int> = [upArrow, downArrow, leftArrow, rightArrow]

    /// Capture blacklist of fixed-direction and modifier/navigation keys that
    /// must keep their system meaning. Unlike the gamepad's small, enumerable
    /// whitelist (``GamepadElementAlias/userBindableAliases``), a keyboard has
    /// too many legitimately bindable keys to whitelist, so bindability is
    /// defined by exclusion instead.
    public static let excludedFromBinding: Set<Int> = fixedDirectionCodes.union([
        escape, tab, capsLock,
        leftControl, leftShift, leftAlt, leftGUI,
        rightControl, rightShift, rightAlt, rightGUI,
    ])

    public static func isUserBindable(_ code: Int) -> Bool {
        !excludedFromBinding.contains(code)
    }

    /// Maps an arrow key code to its fixed ``ReaderControlDirection``, or `nil`
    /// if `code` isn't one of the four arrow keys.
    public static func fixedDirection(forArrowCode code: Int) -> ReaderControlDirection? {
        switch code {
        case upArrow: .up
        case downArrow: .down
        case leftArrow: .left
        case rightArrow: .right
        default: nil
        }
    }
}

public struct KeyboardSettings: Codable, Hashable, Sendable {
    /// Master switch, independent of ``GamepadSettings/isEnabled`` — the two
    /// peripherals are enabled and disabled separately.
    public var isEnabled: Bool

    /// Maps user-bindable actions to a USB HID usage ID (``KeyboardKeyCode``).
    /// An absent key means the action is unbound.
    public var bindings: [ReaderControlAction: Int]

    public init(
        isEnabled: Bool = true,
        bindings: [ReaderControlAction: Int] = Self.defaultBindings
    ) {
        self.isEnabled = isEnabled
        self.bindings = bindings
    }

    public static let defaultBindings: [ReaderControlAction: Int] = [
        .nextPage: KeyboardKeyCode.spacebar,
        .previousPage: KeyboardKeyCode.deleteOrBackspace,
        .openComments: KeyboardKeyCode.keyC,
    ]

    /// A physical key press reports exactly one `GCKeyCode`, unlike a gamepad
    /// button which can report several simultaneous aliases, so lookup takes a
    /// single code rather than ``GamepadSettings/action(boundToAnyOf:)``'s set.
    public func action(boundTo code: Int) -> ReaderControlAction? {
        bindings.first { action, boundCode in
            action.isUserBindable && boundCode == code
        }?.key
    }

    /// Binds `action` to `code`, stealing the code from any action that
    /// currently holds it (last write wins; the losing action becomes unbound).
    public mutating func bind(_ action: ReaderControlAction, toKeyCode code: Int) {
        guard action.isUserBindable else { return }
        for (existingAction, existingCode) in bindings where existingCode == code {
            bindings.removeValue(forKey: existingAction)
        }
        bindings[action] = code
    }

    public mutating func clearBinding(for action: ReaderControlAction) {
        bindings.removeValue(forKey: action)
    }

    public mutating func restoreDefaultBindings() {
        bindings = Self.defaultBindings
    }
}

// MARK: - Input events

public enum ReaderControlDirection: String, Hashable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
}

/// A single logical controller input after the UI glue has done rising-edge
/// detection and binding lookup.
public enum ReaderControlEvent: Hashable, Sendable {
    /// The fixed Menu button.
    case menu
    /// A user-bound button resolved through ``GamepadSettings/bindings``.
    case bound(ReaderControlAction)
    /// A direction-pad press; semantics depend on the active surface.
    case dpad(ReaderControlDirection)
}

/// Tracks per-element pressed state so callers can act exactly once per
/// physical press (rising edge) and ignore analog chatter and releases.
public struct RisingEdgePressTracker: Sendable {
    private var pressedElementKeys: Set<String> = []

    public init() {}

    /// Returns `true` exactly when `key` transitions from released to pressed.
    public mutating func registerPressState(_ isPressed: Bool, forKey key: String) -> Bool {
        if isPressed {
            return pressedElementKeys.insert(key).inserted
        }
        pressedElementKeys.remove(key)
        return false
    }

    public mutating func reset() {
        pressedElementKeys.removeAll()
    }
}

// MARK: - Surface interpretation

public enum ReaderControlScrollDirection: Hashable, Sendable {
    case up
    case down
}

/// What the reader is currently showing, as far as control semantics care.
public enum ReaderControlSurface: Hashable, Sendable {
    case paged(isRightToLeft: Bool)
    case vertical
}

/// A reader-level command produced from a ``ReaderControlEvent``.
public enum ReaderControlCommand: Hashable, Sendable {
    case turnPage(Int)
    case scrollStep(ReaderControlScrollDirection)
    case openComments
    case toggleChrome
}

/// A command for the chapter-comments sheet while it holds control focus.
public enum ReaderControlCommentsCommand: Hashable, Sendable {
    case scroll(ReaderControlScrollDirection)
    case close
}

public enum ReaderControlCommandResolver {
    /// Scroll step height as a fraction of the viewport; the remainder keeps
    /// visual continuity between steps.
    public static let verticalScrollViewportFraction: Double = 0.85

    /// How many comment rows one scroll step advances in the comments sheet.
    public static let commentsScrollStride = 3

    public static func readerCommand(
        for event: ReaderControlEvent,
        surface: ReaderControlSurface
    ) -> ReaderControlCommand? {
        switch event {
        case .menu:
            return .toggleChrome
        case let .bound(action):
            return boundCommand(for: action, surface: surface)
        case let .dpad(direction):
            return dpadCommand(for: direction, surface: surface)
        }
    }

    public static func commentsCommand(for event: ReaderControlEvent) -> ReaderControlCommentsCommand? {
        switch event {
        case .menu, .bound(.openComments):
            .close
        case .dpad(.up):
            .scroll(.up)
        case .dpad(.down):
            .scroll(.down)
        case .bound, .dpad:
            nil
        }
    }

    private static func boundCommand(
        for action: ReaderControlAction,
        surface: ReaderControlSurface
    ) -> ReaderControlCommand? {
        switch (action, surface) {
        case (.nextPage, .paged):
            .turnPage(1)
        case (.previousPage, .paged):
            .turnPage(-1)
        case (.nextPage, .vertical):
            .scrollStep(.down)
        case (.previousPage, .vertical):
            .scrollStep(.up)
        case (.openComments, _):
            .openComments
        case (.toggleChrome, _):
            .toggleChrome
        }
    }

    private static func dpadCommand(
        for direction: ReaderControlDirection,
        surface: ReaderControlSurface
    ) -> ReaderControlCommand? {
        switch surface {
        case let .paged(isRightToLeft):
            switch direction {
            case .up:
                return .turnPage(-1)
            case .down:
                return .turnPage(1)
            case .left:
                return .turnPage(isRightToLeft ? 1 : -1)
            case .right:
                return .turnPage(isRightToLeft ? -1 : 1)
            }
        case .vertical:
            switch direction {
            case .up:
                return .scrollStep(.up)
            case .down:
                return .scrollStep(.down)
            case .left, .right:
                return nil
            }
        }
    }
}
