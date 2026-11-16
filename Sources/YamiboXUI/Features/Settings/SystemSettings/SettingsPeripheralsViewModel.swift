import Foundation
import Observation
import YamiboXCore

/// State and commands for the peripherals page: Apple Pencil page turn,
/// gamepad, hardware keyboard, and external display controls.
@MainActor
@Observable
final class SettingsPeripheralsViewModel: AppSettingsPersisting {
    var applePencilPageTurn = ApplePencilPageTurnSettings()
    var gamepad = GamepadSettings()
    var keyboard = KeyboardSettings()
    var externalDisplay = ExternalDisplaySettings()
    var trackpadSensitivity = ExternalDisplaySettings.defaultTrackpadSensitivity

    let settingsStore: SettingsStore
    let activity: SystemSettingsActivity
    private let settingsTarget: ReaderSettingsTarget

    init(settingsStore: SettingsStore, activity: SystemSettingsActivity, settingsTarget: ReaderSettingsTarget = .device) {
        self.settingsStore = settingsStore
        self.activity = activity
        self.settingsTarget = settingsTarget
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        applePencilPageTurn = settings.system.applePencilPageTurn
        gamepad = settings.system.gamepad
        keyboard = settings.system.keyboard
        externalDisplay = settings.system.externalDisplay
        trackpadSensitivity = settings.trackpadSensitivity(for: settingsTarget)
    }

    /// Reads this page's slice of the settings on its own, for presentations
    /// that are not hosted by ``SystemSettingsViewModel`` — the reader
    /// settings sheets open this page directly, so nobody else does the one
    /// up-front read the settings tab's root performs.
    func load() async {
        activeAction = .loading
        defer { activeAction = nil }
        applyLoadedSettings(await settingsStore.load())
    }

    func restoreDefaultsAfterApplicationReset() { applyLoadedSettings(AppSettings()) }

    func updateExternalDisplayEnabled(_ isEnabled: Bool) {
        persistSettings(\.externalDisplay.isEnabled, to: isEnabled) {
            $0.system.externalDisplay.isEnabled = isEnabled
        }
    }

    func updateTrackpadSensitivity(_ sensitivity: Double) {
        guard trackpadSensitivity != sensitivity else { return }
        let target = settingsTarget
        persistSettings(\.trackpadSensitivity, to: sensitivity) {
            $0.updateTrackpadSensitivity(sensitivity, for: target)
        }
    }

    func updateTrackpadHeightRatio(_ ratio: Double) async -> Bool {
        let ratio = ExternalDisplaySettings.clampTrackpadHeightRatio(ratio)
        return await persistSettings(\.externalDisplay.trackpadHeightRatio, to: ratio) {
            $0.system.externalDisplay.trackpadHeightRatio = ratio
        }.value
    }

    // MARK: - Apple Pencil

    func updateApplePencilPageTurnEnabled(_ isEnabled: Bool) {
        persistSettings(\.applePencilPageTurn.isEnabled, to: isEnabled) {
            $0.system.applePencilPageTurn.isEnabled = isEnabled
        }
    }

    func updateApplePencilPageTurnBehavior(_ behavior: ApplePencilPageTurnBehavior) {
        persistSettings(\.applePencilPageTurn.behavior, to: behavior) {
            $0.system.applePencilPageTurn.behavior = behavior
        }
    }

    // MARK: - Gamepad

    func updateGamepadEnabled(_ isEnabled: Bool) {
        persistSettings(\.gamepad.isEnabled, to: isEnabled) { $0.system.gamepad.isEnabled = isEnabled }
    }

    func bindGamepadAction(_ action: ReaderControlAction, toElementAlias alias: String) {
        var updated = gamepad
        updated.bind(action, toElementAlias: alias)
        persistSettings(\.gamepad.bindings, to: updated.bindings) {
            $0.system.gamepad.bind(action, toElementAlias: alias)
        }
    }

    func clearGamepadBinding(for action: ReaderControlAction) {
        var updated = gamepad
        updated.clearBinding(for: action)
        persistSettings(\.gamepad.bindings, to: updated.bindings) {
            $0.system.gamepad.clearBinding(for: action)
        }
    }

    func restoreGamepadDefaultBindings() {
        var updated = gamepad
        updated.restoreDefaultBindings()
        persistSettings(\.gamepad.bindings, to: updated.bindings) {
            $0.system.gamepad.restoreDefaultBindings()
        }
    }

    // MARK: - Keyboard

    func updateKeyboardEnabled(_ isEnabled: Bool) {
        persistSettings(\.keyboard.isEnabled, to: isEnabled) { $0.system.keyboard.isEnabled = isEnabled }
    }

    func bindKeyboardAction(_ action: ReaderControlAction, toKeyCode code: Int) {
        var updated = keyboard
        updated.bind(action, toKeyCode: code)
        persistSettings(\.keyboard.bindings, to: updated.bindings) {
            $0.system.keyboard.bind(action, toKeyCode: code)
        }
    }

    func clearKeyboardBinding(for action: ReaderControlAction) {
        var updated = keyboard
        updated.clearBinding(for: action)
        persistSettings(\.keyboard.bindings, to: updated.bindings) {
            $0.system.keyboard.clearBinding(for: action)
        }
    }

    func restoreKeyboardDefaultBindings() {
        var updated = keyboard
        updated.restoreDefaultBindings()
        persistSettings(\.keyboard.bindings, to: updated.bindings) {
            $0.system.keyboard.restoreDefaultBindings()
        }
    }
}
