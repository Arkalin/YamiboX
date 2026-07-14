import Foundation
import Testing
@testable import YamiboXCore

// gamepad-control design decisions #3/#13/#14: defaults follow physical
// positions (bottom/left/top face button), Menu is never bindable, and
// rebinding steals the element from whichever action held it.
@Suite("SettingsTests: Gamepad Settings")
struct GamepadSettingsTests {
    @Test func defaultsAreEnabledWithFaceButtonBindings() {
        let settings = GamepadSettings()
        #expect(settings.isEnabled)
        #expect(settings.bindings == [
            .nextPage: GamepadElementAlias.buttonA,
            .previousPage: GamepadElementAlias.buttonX,
            .openComments: GamepadElementAlias.buttonY,
        ])
    }

    @Test func bindingStealsElementFromPreviousOwner() {
        var settings = GamepadSettings()
        settings.bind(.openComments, toElementAlias: GamepadElementAlias.buttonX)
        #expect(settings.bindings[.openComments] == GamepadElementAlias.buttonX)
        #expect(settings.bindings[.previousPage] == nil)
        #expect(settings.bindings[.nextPage] == GamepadElementAlias.buttonA)
    }

    @Test func bindingToFreshElementKeepsOtherBindings() {
        var settings = GamepadSettings()
        settings.bind(.nextPage, toElementAlias: GamepadElementAlias.rightShoulder)
        #expect(settings.bindings[.nextPage] == GamepadElementAlias.rightShoulder)
        #expect(settings.bindings[.previousPage] == GamepadElementAlias.buttonX)
        #expect(settings.bindings[.openComments] == GamepadElementAlias.buttonY)
    }

    @Test func toggleChromeIsNeverBindable() {
        var settings = GamepadSettings()
        settings.bind(.toggleChrome, toElementAlias: GamepadElementAlias.buttonB)
        #expect(settings.bindings[.toggleChrome] == nil)
        #expect(ReaderControlAction.userBindableActions == [.nextPage, .previousPage, .openComments])
    }

    @Test func clearBindingLeavesActionUnbound() {
        var settings = GamepadSettings()
        settings.clearBinding(for: .nextPage)
        #expect(settings.bindings[.nextPage] == nil)
        #expect(settings.action(boundToAnyOf: [GamepadElementAlias.buttonA]) == nil)
    }

    @Test func restoreDefaultBindingsDiscardsCustomization() {
        var settings = GamepadSettings()
        settings.bind(.nextPage, toElementAlias: GamepadElementAlias.leftTrigger)
        settings.clearBinding(for: .openComments)
        settings.restoreDefaultBindings()
        #expect(settings.bindings == GamepadSettings.defaultBindings)
    }

    @Test func actionLookupMatchesAnyAliasInTheSet() {
        let settings = GamepadSettings()
        // Live-input elements report several aliases at once; any hit counts.
        let aliases: Set<String> = ["Button B", GamepadElementAlias.buttonX]
        #expect(settings.action(boundToAnyOf: aliases) == .previousPage)
        #expect(settings.action(boundToAnyOf: ["Left Thumbstick"]) == nil)
    }

    @Test func actionLookupIgnoresNonBindableEntries() {
        // Defensive: a hand-edited or corrupted store must not let Menu's
        // fixed action be shadowed through the bindings table.
        var settings = GamepadSettings()
        settings.bindings[.toggleChrome] = GamepadElementAlias.buttonB
        #expect(settings.action(boundToAnyOf: [GamepadElementAlias.buttonB]) == nil)
    }

    @Test func serializationRoundTripsThroughAppSettings() throws {
        var settings = GamepadSettings()
        settings.isEnabled = false
        settings.bind(.nextPage, toElementAlias: GamepadElementAlias.rightShoulder)
        settings.clearBinding(for: .openComments)

        var appSettings = AppSettings()
        appSettings.system.gamepad = settings

        let data = try JSONEncoder().encode(appSettings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.system.gamepad == settings)
    }

    @Test func bindableAliasWhitelistExcludesFixedAndSystemElements() {
        #expect(GamepadElementAlias.isUserBindable(anyOf: [GamepadElementAlias.buttonA]))
        #expect(GamepadElementAlias.isUserBindable(anyOf: [GamepadElementAlias.leftThumbstickButton]))
        #expect(!GamepadElementAlias.isUserBindable(anyOf: [GamepadElementAlias.buttonMenu]))
        #expect(!GamepadElementAlias.isUserBindable(anyOf: [GamepadElementAlias.buttonHome]))
        #expect(!GamepadElementAlias.isUserBindable(anyOf: [GamepadElementAlias.directionPad]))
        #expect(!GamepadElementAlias.isUserBindable(anyOf: ["Left Thumbstick"]))
        // An element advertising both a bindable and an unknown alias binds.
        #expect(GamepadElementAlias.isUserBindable(anyOf: ["Cross Button", GamepadElementAlias.buttonA]))
    }
}

// gamepad-control design decision #4: actions fire exactly once per physical
// press — on the released→pressed edge — and never on release or repeats.
// (`registerPressState` is mutating, so results are hoisted out of #expect.)
@Suite("SettingsTests: Rising Edge Press Tracker")
struct RisingEdgePressTrackerTests {
    @Test func firesExactlyOnceOnRisingEdge() {
        var tracker = RisingEdgePressTracker()
        let initialPress = tracker.registerPressState(true, forKey: "Button A")
        let heldRepeat = tracker.registerPressState(true, forKey: "Button A")
        let release = tracker.registerPressState(false, forKey: "Button A")
        let secondPress = tracker.registerPressState(true, forKey: "Button A")
        #expect(initialPress)
        #expect(!heldRepeat)
        #expect(!release)
        #expect(secondPress)
    }

    @Test func tracksElementsIndependently() {
        var tracker = RisingEdgePressTracker()
        let pressA = tracker.registerPressState(true, forKey: "Button A")
        let pressX = tracker.registerPressState(true, forKey: "Button X")
        let releaseA = tracker.registerPressState(false, forKey: "Button A")
        let heldX = tracker.registerPressState(true, forKey: "Button X")
        #expect(pressA)
        #expect(pressX)
        #expect(!releaseA)
        #expect(!heldX)
    }

    @Test func resetForgetsHeldButtons() {
        var tracker = RisingEdgePressTracker()
        let firstPress = tracker.registerPressState(true, forKey: "Button A")
        tracker.reset()
        let pressAfterReset = tracker.registerPressState(true, forKey: "Button A")
        #expect(firstPress)
        #expect(pressAfterReset)
    }
}

// gamepad-control design decision #8 (D-pad semantics table) and #11
// (comments-sheet command set). Paged left/right must honor the manga
// right-to-left page turn direction the same way tap zones do.
@Suite("SettingsTests: Reader Control Command Resolver")
struct ReaderControlCommandResolverTests {
    private let ltr = ReaderControlSurface.paged(isRightToLeft: false)
    private let rtl = ReaderControlSurface.paged(isRightToLeft: true)

    @Test func menuTogglesChromeOnEverySurface() {
        #expect(ReaderControlCommandResolver.readerCommand(for: .menu, surface: ltr) == .toggleChrome)
        #expect(ReaderControlCommandResolver.readerCommand(for: .menu, surface: rtl) == .toggleChrome)
        #expect(ReaderControlCommandResolver.readerCommand(for: .menu, surface: .vertical) == .toggleChrome)
    }

    @Test func boundActionsTurnPagesWhenPaged() {
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.nextPage), surface: ltr) == .turnPage(1))
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.previousPage), surface: rtl) == .turnPage(-1))
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.openComments), surface: ltr) == .openComments)
    }

    @Test func boundPageActionsScrollWhenVertical() {
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.nextPage), surface: .vertical) == .scrollStep(.down))
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.previousPage), surface: .vertical) == .scrollStep(.up))
        #expect(ReaderControlCommandResolver.readerCommand(for: .bound(.openComments), surface: .vertical) == .openComments)
    }

    @Test func dpadHorizontalFollowsPageTurnDirection() {
        // Left-to-right: physical left goes back, right advances.
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.left), surface: ltr) == .turnPage(-1))
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.right), surface: ltr) == .turnPage(1))
        // Right-to-left flips horizontal, mirroring directionalTapZone.
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.left), surface: rtl) == .turnPage(1))
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.right), surface: rtl) == .turnPage(-1))
    }

    @Test func dpadVerticalAxisIsDirectionIndependentWhenPaged() {
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.up), surface: ltr) == .turnPage(-1))
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.down), surface: rtl) == .turnPage(1))
    }

    @Test func dpadScrollsWhenVerticalAndHorizontalIsDead() {
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.up), surface: .vertical) == .scrollStep(.up))
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.down), surface: .vertical) == .scrollStep(.down))
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.left), surface: .vertical) == nil)
        #expect(ReaderControlCommandResolver.readerCommand(for: .dpad(.right), surface: .vertical) == nil)
    }

    @Test func commentsSheetScrollsClosesAndIgnoresTheRest() {
        #expect(ReaderControlCommandResolver.commentsCommand(for: .dpad(.up)) == .scroll(.up))
        #expect(ReaderControlCommandResolver.commentsCommand(for: .dpad(.down)) == .scroll(.down))
        #expect(ReaderControlCommandResolver.commentsCommand(for: .bound(.openComments)) == .close)
        #expect(ReaderControlCommandResolver.commentsCommand(for: .menu) == .close)
        #expect(ReaderControlCommandResolver.commentsCommand(for: .bound(.nextPage)) == nil)
        #expect(ReaderControlCommandResolver.commentsCommand(for: .bound(.previousPage)) == nil)
        #expect(ReaderControlCommandResolver.commentsCommand(for: .dpad(.left)) == nil)
        #expect(ReaderControlCommandResolver.commentsCommand(for: .dpad(.right)) == nil)
    }
}

// keyboard-control design decisions #7/#8: independent KeyboardSettings keyed
// by GCKeyCode.rawValue (Int), enabled independently of the gamepad, with
// Space/Backspace/C as the out-of-the-box defaults.
@Suite("SettingsTests: Keyboard Settings")
struct KeyboardSettingsTests {
    @Test func defaultsAreEnabledWithSpaceBackspaceCBindings() {
        let settings = KeyboardSettings()
        #expect(settings.isEnabled)
        #expect(settings.bindings == [
            .nextPage: KeyboardKeyCode.spacebar,
            .previousPage: KeyboardKeyCode.deleteOrBackspace,
            .openComments: KeyboardKeyCode.keyC,
        ])
    }

    @Test func bindingStealsKeyCodeFromPreviousOwner() {
        var settings = KeyboardSettings()
        settings.bind(.openComments, toKeyCode: KeyboardKeyCode.deleteOrBackspace)
        #expect(settings.bindings[.openComments] == KeyboardKeyCode.deleteOrBackspace)
        #expect(settings.bindings[.previousPage] == nil)
        #expect(settings.bindings[.nextPage] == KeyboardKeyCode.spacebar)
    }

    @Test func bindingToFreshKeyCodeKeepsOtherBindings() {
        var settings = KeyboardSettings()
        let keyM = 0x10
        settings.bind(.nextPage, toKeyCode: keyM)
        #expect(settings.bindings[.nextPage] == keyM)
        #expect(settings.bindings[.previousPage] == KeyboardKeyCode.deleteOrBackspace)
        #expect(settings.bindings[.openComments] == KeyboardKeyCode.keyC)
    }

    @Test func toggleChromeIsNeverBindable() {
        var settings = KeyboardSettings()
        settings.bind(.toggleChrome, toKeyCode: KeyboardKeyCode.keyC)
        #expect(settings.bindings[.toggleChrome] == nil)
        #expect(ReaderControlAction.userBindableActions == [.nextPage, .previousPage, .openComments])
    }

    @Test func clearBindingLeavesActionUnbound() {
        var settings = KeyboardSettings()
        settings.clearBinding(for: .nextPage)
        #expect(settings.bindings[.nextPage] == nil)
        #expect(settings.action(boundTo: KeyboardKeyCode.spacebar) == nil)
    }

    @Test func restoreDefaultBindingsDiscardsCustomization() {
        var settings = KeyboardSettings()
        settings.bind(.nextPage, toKeyCode: 0x10)
        settings.clearBinding(for: .openComments)
        settings.restoreDefaultBindings()
        #expect(settings.bindings == KeyboardSettings.defaultBindings)
    }

    @Test func actionLookupIgnoresNonBindableEntries() {
        // Defensive: a hand-edited or corrupted store must not let the fixed
        // toggleChrome action be shadowed through the bindings table.
        var settings = KeyboardSettings()
        let keyM = 0x10
        settings.bindings[.toggleChrome] = keyM
        #expect(settings.action(boundTo: keyM) == nil)
    }

    @Test func serializationRoundTripsThroughAppSettings() throws {
        var settings = KeyboardSettings()
        settings.isEnabled = false
        settings.bind(.nextPage, toKeyCode: 0x10)
        settings.clearBinding(for: .openComments)

        var appSettings = AppSettings()
        appSettings.system.keyboard = settings

        let data = try JSONEncoder().encode(appSettings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.system.keyboard == settings)
    }
}

// keyboard-control design decisions #4/#6: Esc and the four arrow keys carry
// fixed semantics like the gamepad's Menu/D-pad, and a blacklist (not a
// whitelist) excludes them plus the eight modifier keys from binding.
@Suite("SettingsTests: Keyboard Key Code")
struct KeyboardKeyCodeTests {
    @Test func ordinaryKeysAreUserBindable() {
        #expect(KeyboardKeyCode.isUserBindable(KeyboardKeyCode.spacebar))
        #expect(KeyboardKeyCode.isUserBindable(KeyboardKeyCode.deleteOrBackspace))
        #expect(KeyboardKeyCode.isUserBindable(KeyboardKeyCode.keyC))
    }

    @Test func fixedDirectionKeysAreNotUserBindable() {
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.upArrow))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.downArrow))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.leftArrow))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.rightArrow))
    }

    @Test func escapeTabAndCapsLockAreNotUserBindable() {
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.escape))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.tab))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.capsLock))
    }

    @Test func modifierKeysAreNotUserBindable() {
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.leftControl))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.rightControl))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.leftShift))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.rightShift))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.leftAlt))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.rightAlt))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.leftGUI))
        #expect(!KeyboardKeyCode.isUserBindable(KeyboardKeyCode.rightGUI))
    }

    @Test func fixedDirectionMapsEachArrowToItsReaderControlDirection() {
        #expect(KeyboardKeyCode.fixedDirection(forArrowCode: KeyboardKeyCode.upArrow) == .up)
        #expect(KeyboardKeyCode.fixedDirection(forArrowCode: KeyboardKeyCode.downArrow) == .down)
        #expect(KeyboardKeyCode.fixedDirection(forArrowCode: KeyboardKeyCode.leftArrow) == .left)
        #expect(KeyboardKeyCode.fixedDirection(forArrowCode: KeyboardKeyCode.rightArrow) == .right)
    }

    @Test func fixedDirectionReturnsNilForNonArrowCode() {
        #expect(KeyboardKeyCode.fixedDirection(forArrowCode: KeyboardKeyCode.spacebar) == nil)
    }
}
