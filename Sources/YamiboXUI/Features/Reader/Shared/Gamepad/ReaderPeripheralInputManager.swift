#if os(iOS)
import Foundation
import GameController
import Observation
import YamiboXCore

/// App-wide game-controller and hardware-keyboard listener. Translates
/// `GCControllerLiveInput` element changes and `GCKeyboard` key changes into
/// the same logical ``ReaderControlEvent``s and delivers them to the top of a
/// consumer stack (reader below, comments sheet above). The settings page can
/// preempt either source's dispatch with a capture session to bind buttons or
/// keys.
///
/// Listens to every connected controller and the coalesced hardware keyboard
/// at once; the readers gate on their own presentation state, this class only
/// gates on each source's own master switch (``GamepadSettings/isEnabled``,
/// ``KeyboardSettings/isEnabled`` — independent of each other).
@MainActor
@Observable
public final class ReaderPeripheralInputManager {
    public struct CapturedElement: Hashable, Sendable {
        public let alias: String
        public let sfSymbolsName: String?
        public let localizedName: String?

        public init(alias: String, sfSymbolsName: String?, localizedName: String?) {
            self.alias = alias
            self.sfSymbolsName = sfSymbolsName
            self.localizedName = localizedName
        }
    }

    public enum CaptureFeedback: Hashable, Sendable {
        /// A bindable element was pressed; the capture session has ended.
        case captured(CapturedElement)
        /// A fixed/system element was pressed; the session keeps waiting.
        case rejected
    }

    public struct ElementDisplayInfo: Hashable, Sendable {
        public let sfSymbolsName: String?
        public let localizedName: String?
    }

    /// A captured keyboard key, mirroring ``CapturedElement`` for the keyboard
    /// capture path. Kept as a separate, parallel type rather than unified
    /// with the gamepad one — keyboard bindings persist an `Int` key code,
    /// not a `String` alias.
    public struct CapturedKey: Hashable, Sendable {
        public let keyCode: Int
        public let displayName: String?

        public init(keyCode: Int, displayName: String?) {
            self.keyCode = keyCode
            self.displayName = displayName
        }
    }

    public enum KeyboardCaptureFeedback: Hashable, Sendable {
        /// A bindable key was pressed; the capture session has ended.
        case captured(CapturedKey)
        /// A fixed/system key was pressed; the session keeps waiting.
        case rejected
    }

    /// Vendor names of every connected controller, for the settings page.
    public private(set) var connectedControllerNames: [String] = []

    public var isControllerConnected: Bool {
        !connectedControllerNames.isEmpty
    }

    /// Whether a hardware keyboard is currently connected. `GCKeyboard.coalesced`
    /// merges every connected keyboard into a single logical device with no
    /// per-device identity, so unlike ``connectedControllerNames`` there is
    /// nothing to enumerate here — just a boolean.
    public private(set) var isKeyboardConnected: Bool = false

    @ObservationIgnored private var settings = GamepadSettings()
    @ObservationIgnored private var keyboardSettings = KeyboardSettings()
    @ObservationIgnored private var handlerStack: [(token: UUID, handler: (ReaderControlEvent) -> Void)] = []
    @ObservationIgnored private var captureHandler: ((CaptureFeedback) -> Void)?
    @ObservationIgnored private var keyboardCaptureHandler: ((KeyboardCaptureFeedback) -> Void)?
    @ObservationIgnored private var pressTracker = RisingEdgePressTracker()
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var monitorTasks: [Task<Void, Never>] = []

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        startMonitoring()
    }

    deinit {
        for task in monitorTasks {
            task.cancel()
        }
    }

    // MARK: - Consumer stack

    /// Registers `handler` as the active event consumer, stacking above any
    /// current one. Returns a token for ``removeHandler(_:)`` on disappear.
    @discardableResult
    public func pushHandler(_ handler: @escaping (ReaderControlEvent) -> Void) -> UUID {
        let token = UUID()
        handlerStack.append((token, handler))
        return token
    }

    public func removeHandler(_ token: UUID?) {
        guard let token else { return }
        handlerStack.removeAll { $0.token == token }
    }

    // MARK: - Binding capture

    /// Suspends event dispatch and reports the next press instead. Bindable
    /// presses end the session; excluded ones emit `.rejected` and keep it
    /// alive. Works regardless of the master switch so the settings page can
    /// always rebind.
    public func beginCapture(_ feedback: @escaping (CaptureFeedback) -> Void) {
        captureHandler = feedback
    }

    public func cancelCapture() {
        captureHandler = nil
    }

    /// Looks up display metadata for a persisted alias on the currently
    /// connected controllers, so bound rows can render real glyphs.
    public func displayInfo(forElementAlias alias: String) -> ElementDisplayInfo? {
        for controller in GCController.controllers() {
            guard let element = controller.physicalInputProfile.elements[alias] else { continue }
            return ElementDisplayInfo(
                sfSymbolsName: element.sfSymbolsName,
                localizedName: element.localizedName
            )
        }
        return nil
    }

    // MARK: - Keyboard binding capture

    /// Suspends keyboard event dispatch and reports the next key press
    /// instead. Bindable presses end the session; excluded ones (Escape, the
    /// arrows, modifiers, etc.) emit `.rejected` and keep it alive. Works
    /// regardless of ``KeyboardSettings/isEnabled``, the same way
    /// ``beginCapture(_:)`` works regardless of the gamepad's master switch.
    ///
    /// A separate, parallel API from the gamepad capture pair above — kept
    /// independent rather than unified because the two persist different
    /// value types (`String` alias vs. `Int` key code).
    public func beginKeyboardCapture(_ feedback: @escaping (KeyboardCaptureFeedback) -> Void) {
        keyboardCaptureHandler = feedback
    }

    public func cancelKeyboardCapture() {
        keyboardCaptureHandler = nil
    }

    /// Best-effort human-readable name for a key code, used both to label a
    /// just-captured key and to render already-bound keys in the settings
    /// list — mirrors ``displayInfo(forElementAlias:)`` returning `nil` for
    /// an unknown alias and leaving rendering to the UI layer.
    ///
    /// GameController has no static code -> name lookup independent of a
    /// live keyboard, unlike `GCPhysicalInputElement.localizedName` for
    /// controller elements. This implements the first two tiers of the PRD's
    /// three-tier fallback chain (docs/issues/keyboard-control/prd.md
    /// decision 7): it tries the connected keyboard's own button first, then
    /// falls back to a small hardcoded table covering the common bindable
    /// keys (letters, digits, punctuation, F-keys, Return/Enter), then
    /// returns `nil`. The third tier — displaying the raw code (e.g. "Key
    /// code 21") — is a UI-layer concern for whoever renders a `nil` result,
    /// same as an unknown gamepad alias falls back to its raw string today.
    /// This is a known soft spot: real-device and simulator validation may
    /// reveal a better system API than `localizedName` for tier one.
    public func displayName(forKeyCode code: Int) -> String? {
        if let liveName = GCKeyboard.coalesced?.keyboardInput?
            .button(forKeyCode: GCKeyCode(rawValue: code))?.localizedName {
            return liveName
        }
        return Self.fallbackKeyDisplayNames[code]
    }

    // MARK: - Controller monitoring

    private func startMonitoring() {
        for controller in GCController.controllers() {
            attach(controller)
        }
        refreshConnectionState()

        if let keyboard = GCKeyboard.coalesced {
            attach(keyboard)
        }
        refreshKeyboardConnectionState()

        monitorTasks.append(Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .GCControllerDidConnect) {
                guard !Task.isCancelled else { return }
                guard let controller = notification.object as? GCController else { continue }
                guard let self else { return }
                self.attach(controller)
                self.refreshConnectionState()
            }
        })
        monitorTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .GCControllerDidDisconnect) {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.pressTracker.reset()
                self.refreshConnectionState()
            }
        })
        monitorTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .GCKeyboardDidConnect) {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let keyboard = GCKeyboard.coalesced {
                    self.attach(keyboard)
                }
                self.refreshKeyboardConnectionState()
            }
        })
        monitorTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .GCKeyboardDidDisconnect) {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.pressTracker.reset()
                self.refreshKeyboardConnectionState()
            }
        })
        // `settingsStore` is captured directly (not through weak `self`) so
        // the stream subscription can outlive `self` until deinit cancels the
        // task — the same lifetime the old NotificationCenter loop had. No
        // changeID guard here, as before: every settings change through the
        // store this manager holds should reload, own writes included.
        monitorTasks.append(Task { [weak self, settingsStore] in
            await self?.reloadSettings()
            for await _ in settingsStore.changes() {
                guard !Task.isCancelled else { return }
                await self?.reloadSettings()
            }
        })
    }

    private func reloadSettings() async {
        let system = await settingsStore.load().system
        settings = system.gamepad
        keyboardSettings = system.keyboard
    }

    private func refreshConnectionState() {
        connectedControllerNames = GCController.controllers().map {
            $0.vendorName ?? $0.productCategory
        }
    }

    private func attach(_ controller: GCController) {
        let controllerKey = ObjectIdentifier(controller)
        let input = controller.input
        input.queue = .main
        input.elementValueDidChangeHandler = { [weak self] _, element in
            MainActor.assumeIsolated {
                self?.handleElementChange(element, controllerKey: controllerKey)
            }
        }
    }

    // MARK: - Keyboard monitoring

    private func refreshKeyboardConnectionState() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.handlerQueue = .main
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, isPressed in
            MainActor.assumeIsolated {
                self?.handleKeyChange(keyCode, isPressed: isPressed)
            }
        }
    }

    // MARK: - Event translation

    private func handleElementChange(_ element: any GCPhysicalInputElement, controllerKey: ObjectIdentifier) {
        if let button = element as? GCButtonElement {
            let aliases = button.aliases
            guard registerPress(
                button.pressedInput.isPressed,
                key: "\(controllerKey)#\(aliases.sorted().first ?? "?")"
            ) else { return }
            routeButtonPress(aliases: aliases)
            return
        }

        // Thumbsticks surface as direction-pad elements too; only the real
        // pad carries fixed directional semantics (sticks stay ignored).
        if let dpad = element as? GCDirectionPadElement,
           dpad.aliases.contains(GamepadElementAlias.directionPad) {
            let cardinals: [(ReaderControlDirection, any GCPressedStateInput)] = [
                (.up, dpad.up), (.down, dpad.down), (.left, dpad.left), (.right, dpad.right),
            ]
            for (direction, pressedInput) in cardinals {
                guard registerPress(
                    pressedInput.isPressed,
                    key: "\(controllerKey)#dpad.\(direction.rawValue)"
                ) else { continue }
                routeDpadPress(direction)
            }
        }
    }

    private func registerPress(_ isPressed: Bool, key: String) -> Bool {
        pressTracker.registerPressState(isPressed, forKey: key)
    }

    private func routeButtonPress(aliases: Set<String>) {
        if let captureHandler {
            guard let alias = GamepadElementAlias.canonicalBindableAlias(in: aliases) else {
                captureHandler(.rejected)
                return
            }
            let display = displayInfo(forElementAlias: alias)
            self.captureHandler = nil
            captureHandler(.captured(CapturedElement(
                alias: alias,
                sfSymbolsName: display?.sfSymbolsName,
                localizedName: display?.localizedName
            )))
            return
        }

        guard settings.isEnabled, let handler = handlerStack.last?.handler else { return }
        if aliases.contains(GamepadElementAlias.buttonMenu) {
            handler(.menu)
            return
        }
        guard let action = settings.action(boundToAnyOf: aliases) else { return }
        handler(.bound(action))
    }

    private func routeDpadPress(_ direction: ReaderControlDirection) {
        if let captureHandler {
            captureHandler(.rejected)
            return
        }
        guard settings.isEnabled, let handler = handlerStack.last?.handler else { return }
        handler(.dpad(direction))
    }

    // MARK: - Keyboard event translation

    private func handleKeyChange(_ keyCode: GCKeyCode, isPressed: Bool) {
        guard registerPress(isPressed, key: "keyboard#\(keyCode.rawValue)") else { return }
        routeKeyPress(code: keyCode.rawValue)
    }

    private func routeKeyPress(code: Int) {
        if let keyboardCaptureHandler {
            guard KeyboardKeyCode.isUserBindable(code) else {
                keyboardCaptureHandler(.rejected)
                return
            }
            let captured = CapturedKey(keyCode: code, displayName: displayName(forKeyCode: code))
            self.keyboardCaptureHandler = nil
            keyboardCaptureHandler(.captured(captured))
            return
        }

        guard keyboardSettings.isEnabled, let handler = handlerStack.last?.handler else { return }
        if code == KeyboardKeyCode.escape {
            handler(.menu)
            return
        }
        if let direction = KeyboardKeyCode.fixedDirection(forArrowCode: code) {
            handler(.dpad(direction))
            return
        }
        guard let action = keyboardSettings.action(boundTo: code) else { return }
        handler(.bound(action))
    }

    /// Hardcoded fallback for ``displayName(forKeyCode:)`` when no live
    /// keyboard button name is available. Covers the common bindable keys a
    /// user would realistically bind: letters, digits, common punctuation,
    /// F1–F12, and Return/Enter. Keyed by the same USB HID usage IDs as
    /// ``KeyboardKeyCode``; see the "Keyboard/Keypad Page (0x07)" of the USB
    /// HID Usage Tables.
    private static let fallbackKeyDisplayNames: [Int: String] = {
        var names: [Int: String] = [:]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            names[0x04 + offset] = String(letter)
        }
        for (offset, digit) in "1234567890".enumerated() {
            names[0x1E + offset] = String(digit)
        }
        for index in 1...12 {
            names[0x3A + (index - 1)] = "F\(index)"
        }
        names[0x28] = "Return"
        names[KeyboardKeyCode.spacebar] = "Space"
        names[KeyboardKeyCode.deleteOrBackspace] = "Delete"
        names[0x2D] = "-"
        names[0x2E] = "="
        names[0x2F] = "["
        names[0x30] = "]"
        names[0x31] = "\\"
        names[0x33] = ";"
        names[0x34] = "'"
        names[0x35] = "`"
        names[0x36] = ","
        names[0x37] = "."
        names[0x38] = "/"
        return names
    }()
}
#endif
