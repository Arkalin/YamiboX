#if os(iOS)
import Foundation
import GameController
import Observation
import UIKit
import YamiboXCore

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
        case captured(CapturedElement)
        case rejected
    }

    public struct ElementDisplayInfo: Hashable, Sendable {
        public let sfSymbolsName: String?
        public let localizedName: String?
    }

    public struct CapturedKey: Hashable, Sendable {
        public let keyCode: Int
        public let displayName: String?

        public init(keyCode: Int, displayName: String?) {
            self.keyCode = keyCode
            self.displayName = displayName
        }
    }

    public enum KeyboardCaptureFeedback: Hashable, Sendable {
        case captured(CapturedKey)
        case rejected
    }

    public private(set) var connectedControllerNames: [String] = []

    public var isControllerConnected: Bool {
        !connectedControllerNames.isEmpty
    }

    public private(set) var isKeyboardConnected: Bool = false

    @ObservationIgnored private var settings = GamepadSettings()
    @ObservationIgnored private var keyboardSettings = KeyboardSettings()
    @ObservationIgnored private var handlerStack: [(token: UUID, handler: (ReaderControlEvent) -> Void)] = []
    @ObservationIgnored private var captureHandler: ((CaptureFeedback) -> Void)?
    @ObservationIgnored private var keyboardCaptureHandler: ((KeyboardCaptureFeedback) -> Void)?
    @ObservationIgnored private var pressTracker = RisingEdgePressTracker()
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var monitorTasks: [Task<Void, Never>] = []
    @ObservationIgnored private let usesWindowKeyboardEvents: Bool
    @ObservationIgnored private let acceptsInput: @MainActor () -> Bool
    @ObservationIgnored private let acceptsCaptureInput: (@MainActor () -> Bool)?
    private static var managers: [WeakManager] = []

    public init(
        settingsStore: SettingsStore,
        usesWindowKeyboardEvents: Bool = false,
        acceptsInput: @escaping @MainActor () -> Bool = { true },
        acceptsCaptureInput: (@MainActor () -> Bool)? = nil
    ) {
        self.settingsStore = settingsStore
        self.usesWindowKeyboardEvents = usesWindowKeyboardEvents
        self.acceptsInput = acceptsInput
        self.acceptsCaptureInput = acceptsCaptureInput
        Self.managers.removeAll { $0.value == nil }
        Self.managers.append(WeakManager(self))
        startMonitoring()
    }

    deinit {
        for task in monitorTasks {
            task.cancel()
        }
    }

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

    func dispatchExternalPageStep(_ direction: ReaderControlScrollDirection) -> Bool {
        guard allowsEvent(isCapturing: false), let handler = handlerStack.last?.handler else { return false }
        handler(.externalPageStep(direction))
        return true
    }

    public func beginCapture(_ feedback: @escaping (CaptureFeedback) -> Void) {
        captureHandler = feedback
    }

    public func cancelCapture() {
        captureHandler = nil
    }

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

    public func beginKeyboardCapture(_ feedback: @escaping (KeyboardCaptureFeedback) -> Void) {
        keyboardCaptureHandler = feedback
    }

    public func cancelKeyboardCapture() {
        keyboardCaptureHandler = nil
    }

    public func displayName(forKeyCode code: Int) -> String? {
        if let liveName = GCKeyboard.coalesced?.keyboardInput?
            .button(forKeyCode: GCKeyCode(rawValue: code))?.localizedName {
            return liveName
        }
        return Self.fallbackKeyDisplayNames[code]
    }

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
        input.elementValueDidChangeHandler = { _, element in
            MainActor.assumeIsolated {
                Self.forEachManager { $0.handleElementChange(element, controllerKey: controllerKey) }
            }
        }
    }

    private func refreshKeyboardConnectionState() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.handlerQueue = .main
        keyboard.keyboardInput?.keyChangedHandler = { _, _, keyCode, isPressed in
            MainActor.assumeIsolated {
                Self.forEachManager { manager in
                    if !manager.usesWindowKeyboardEvents {
                        manager.handleKeyChange(keyCode, isPressed: isPressed)
                    }
                }
            }
        }
    }

    private func handleElementChange(_ element: any GCPhysicalInputElement, controllerKey: ObjectIdentifier) {
        guard allowsEvent(isCapturing: captureHandler != nil) else {
            pressTracker.reset()
            return
        }
        if let button = element as? GCButtonElement {
            let aliases = button.aliases
            guard registerPress(
                button.pressedInput.isPressed,
                key: "\(controllerKey)#\(aliases.sorted().first ?? "?")"
            ) else { return }
            routeButtonPress(aliases: aliases)
            return
        }

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

    private func handleKeyChange(_ keyCode: GCKeyCode, isPressed: Bool) {
        guard allowsEvent(isCapturing: keyboardCaptureHandler != nil) else {
            pressTracker.reset()
            return
        }
        guard registerPress(isPressed, key: "keyboard#\(keyCode.rawValue)") else { return }
        routeKeyPress(code: keyCode.rawValue)
    }

    func handleWindowKey(code: Int, isPressed: Bool, isEditingText: Bool, hasCommandModifier: Bool) {
        guard usesWindowKeyboardEvents else { return }
        guard !isPressed || (!isEditingText && !hasCommandModifier) else { return }
        handleKeyChange(GCKeyCode(rawValue: code), isPressed: isPressed)
    }

    func resetPressState() { pressTracker.reset() }

    private func allowsEvent(isCapturing: Bool) -> Bool {
        if isCapturing, let acceptsCaptureInput { return acceptsCaptureInput() }
        return acceptsInput()
    }

    private static func forEachManager(_ body: (ReaderPeripheralInputManager) -> Void) {
        managers.removeAll { $0.value == nil }
        for manager in managers.compactMap(\.value) { body(manager) }
    }

    private final class WeakManager {
        weak var value: ReaderPeripheralInputManager?
        init(_ value: ReaderPeripheralInputManager) { self.value = value }
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
