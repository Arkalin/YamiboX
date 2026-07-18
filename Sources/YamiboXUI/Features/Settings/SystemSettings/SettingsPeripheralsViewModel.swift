import Foundation
import Observation
import YamiboXCore

/// State and commands for the peripherals page: Apple Pencil page turn,
/// gamepad, and hardware keyboard bindings.
@MainActor
@Observable
final class SettingsPeripheralsViewModel: AppSettingsPersisting {
    var applePencilPageTurn = ApplePencilPageTurnSettings()
    var gamepad = GamepadSettings()
    var keyboard = KeyboardSettings()

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        applePencilPageTurn = settings.system.applePencilPageTurn
        gamepad = settings.system.gamepad
        keyboard = settings.system.keyboard
    }

    func restoreDefaultsAfterApplicationReset() {
        applePencilPageTurn = ApplePencilPageTurnSettings()
        gamepad = GamepadSettings()
        keyboard = KeyboardSettings()
    }

    // MARK: - Apple Pencil

    func updateApplePencilPageTurnEnabled(_ isEnabled: Bool) {
        var updated = applePencilPageTurn
        updated.isEnabled = isEnabled
        updateApplePencilPageTurn(updated)
    }

    func updateApplePencilPageTurnBehavior(_ behavior: ApplePencilPageTurnBehavior) {
        var updated = applePencilPageTurn
        updated.behavior = behavior
        updateApplePencilPageTurn(updated)
    }

    private func updateApplePencilPageTurn(_ updated: ApplePencilPageTurnSettings) {
        persistSettings(\.applePencilPageTurn, to: updated) { $0.system.applePencilPageTurn = updated }
    }

    // MARK: - Gamepad

    func updateGamepadEnabled(_ isEnabled: Bool) {
        var updated = gamepad
        updated.isEnabled = isEnabled
        updateGamepad(updated)
    }

    func bindGamepadAction(_ action: ReaderControlAction, toElementAlias alias: String) {
        var updated = gamepad
        updated.bind(action, toElementAlias: alias)
        updateGamepad(updated)
    }

    func clearGamepadBinding(for action: ReaderControlAction) {
        var updated = gamepad
        updated.clearBinding(for: action)
        updateGamepad(updated)
    }

    func restoreGamepadDefaultBindings() {
        var updated = gamepad
        updated.restoreDefaultBindings()
        updateGamepad(updated)
    }

    private func updateGamepad(_ updated: GamepadSettings) {
        persistSettings(\.gamepad, to: updated) { $0.system.gamepad = updated }
    }

    // MARK: - Keyboard

    func updateKeyboardEnabled(_ isEnabled: Bool) {
        var updated = keyboard
        updated.isEnabled = isEnabled
        updateKeyboard(updated)
    }

    func bindKeyboardAction(_ action: ReaderControlAction, toKeyCode code: Int) {
        var updated = keyboard
        updated.bind(action, toKeyCode: code)
        updateKeyboard(updated)
    }

    func clearKeyboardBinding(for action: ReaderControlAction) {
        var updated = keyboard
        updated.clearBinding(for: action)
        updateKeyboard(updated)
    }

    func restoreKeyboardDefaultBindings() {
        var updated = keyboard
        updated.restoreDefaultBindings()
        updateKeyboard(updated)
    }

    private func updateKeyboard(_ updated: KeyboardSettings) {
        persistSettings(\.keyboard, to: updated) { $0.system.keyboard = updated }
    }
}
