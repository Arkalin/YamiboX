import SwiftUI
import YamiboXCore
import UIKit

struct SystemSettingsPeripheralPageTurnView: View {
    let viewModel: SettingsPeripheralsViewModel
    var peripheralInput: ReaderPeripheralInputManager?
    @State private var showsApplePencilHelp = false
    @State private var capturingAction: ReaderControlAction?
    @State private var showsCaptureRejectedNotice = false
    @State private var captureRejectionDismissTask: Task<Void, Never>?
    @State private var capturingKeyboardAction: ReaderControlAction?
    @State private var showsKeyboardCaptureRejectedNotice = false
    @State private var keyboardCaptureRejectionDismissTask: Task<Void, Never>?

    private var showsApplePencilSection: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var isControllerConnected: Bool {
        peripheralInput?.isControllerConnected == true
    }

    private var isKeyboardConnected: Bool {
        peripheralInput?.isKeyboardConnected == true
    }

    var body: some View {
        Form {
            if showsApplePencilSection {
                Section("Apple Pencil") {
                    HStack(spacing: 8) {
                        Text(L10n.string("apple_pencil.page_turn"))
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsApplePencilHelp.toggle()
                            }
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .expandedHitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("apple_pencil.help_toggle"))
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { viewModel.applePencilPageTurn.isEnabled },
                            set: { viewModel.updateApplePencilPageTurnEnabled($0) }
                        ))
                        .labelsHidden()
                        .disabled(viewModel.isBusy)
                    }
                    if showsApplePencilHelp {
                        Text(L10n.string("apple_pencil.help"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Picker(
                        L10n.string("apple_pencil.behavior.title"),
                        selection: Binding(
                            get: { viewModel.applePencilPageTurn.behavior },
                            set: { viewModel.updateApplePencilPageTurnBehavior($0) }
                        )
                    ) {
                        ForEach(ApplePencilPageTurnBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .disabled(viewModel.isBusy)
                }
            }

            Section {
                connectionStatusRow
                Toggle(L10n.string("settings.gamepad.enabled"), isOn: Binding(
                    get: { viewModel.gamepad.isEnabled },
                    set: { viewModel.updateGamepadEnabled($0) }
                ))
                .disabled(viewModel.isBusy)
                ForEach(ReaderControlAction.userBindableActions, id: \.self) { action in
                    gamepadBindingRow(action)
                }
                fixedMenuRow
                Button(L10n.string("settings.gamepad.restore_defaults")) {
                    cancelCaptureIfNeeded()
                    viewModel.restoreGamepadDefaultBindings()
                }
                .disabled(viewModel.isBusy)
            } header: {
                Text(L10n.string("settings.gamepad"))
            } footer: {
                Text(gamepadFooterText)
            }

            Section {
                keyboardConnectionStatusRow
                Toggle(L10n.string("settings.keyboard.enabled"), isOn: Binding(
                    get: { viewModel.keyboard.isEnabled },
                    set: { viewModel.updateKeyboardEnabled($0) }
                ))
                .disabled(viewModel.isBusy)
                ForEach(ReaderControlAction.userBindableActions, id: \.self) { action in
                    keyboardBindingRow(action)
                }
                fixedKeyboardMenuRow
                Button(L10n.string("settings.keyboard.restore_defaults")) {
                    cancelKeyboardCaptureIfNeeded()
                    viewModel.restoreKeyboardDefaultBindings()
                }
                .disabled(viewModel.isBusy)
            } header: {
                Text(L10n.string("settings.keyboard"))
            } footer: {
                Text(keyboardFooterText)
            }
        }
        .navigationTitle(L10n.string("settings.peripheral_behavior"))
        .onDisappear {
            cancelCaptureIfNeeded()
            cancelKeyboardCaptureIfNeeded()
        }
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }

    private var connectionStatusRow: some View {
        HStack(spacing: 12) {
            Text(L10n.string("settings.gamepad.status"))
            Spacer(minLength: 0)
            Text(connectionStatusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var connectionStatusText: String {
        guard let peripheralInput, peripheralInput.isControllerConnected else {
            return L10n.string("settings.gamepad.status.disconnected")
        }
        return L10n.string(
            "settings.gamepad.status.connected",
            peripheralInput.connectedControllerNames.joined(separator: "、")
        )
    }

    private var fixedMenuRow: some View {
        HStack(spacing: 12) {
            Text(ReaderControlAction.toggleChrome.title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(L10n.string("settings.gamepad.menu_fixed"))
                .foregroundStyle(.secondary)
        }
    }

    private var gamepadFooterText: String {
        var lines = [L10n.string("settings.gamepad.dpad_note")]
        if !isControllerConnected {
            lines.append(L10n.string("settings.gamepad.connect_hint"))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func gamepadBindingRow(_ action: ReaderControlAction) -> some View {
        if capturingAction == action {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(action.title)
                    Spacer(minLength: 8)
                    Text(showsCaptureRejectedNotice
                        ? L10n.string("settings.gamepad.capture_rejected")
                        : L10n.string("settings.gamepad.capture_prompt"))
                        .font(.footnote)
                        .foregroundStyle(showsCaptureRejectedNotice ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                HStack(spacing: 20) {
                    Button(L10n.string("common.cancel")) {
                        cancelCaptureIfNeeded()
                    }
                    if viewModel.gamepad.bindings[action] != nil {
                        Button(L10n.string("settings.gamepad.clear_binding"), role: .destructive) {
                            cancelCaptureIfNeeded()
                            viewModel.clearGamepadBinding(for: action)
                        }
                    }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        } else {
            Button {
                beginCapture(for: action)
            } label: {
                HStack(spacing: 12) {
                    Text(action.title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    bindingValueLabel(for: action)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy || !isControllerConnected || capturingAction != nil)
        }
    }

    @ViewBuilder
    private func bindingValueLabel(for action: ReaderControlAction) -> some View {
        if let alias = viewModel.gamepad.bindings[action] {
            let display = peripheralInput?.displayInfo(forElementAlias: alias)
            HStack(spacing: 6) {
                if let symbolName = display?.sfSymbolsName {
                    Image(systemName: symbolName)
                }
                Text(display?.localizedName ?? alias)
            }
            .foregroundStyle(.secondary)
        } else {
            Text(L10n.string("settings.gamepad.unset"))
                .foregroundStyle(.secondary)
        }
    }

    private func beginCapture(for action: ReaderControlAction) {
        guard let peripheralInput else { return }
        capturingAction = action
        showsCaptureRejectedNotice = false
        peripheralInput.beginCapture { feedback in
            switch feedback {
            case let .captured(element):
                captureRejectionDismissTask?.cancel()
                capturingAction = nil
                showsCaptureRejectedNotice = false
                viewModel.bindGamepadAction(action, toElementAlias: element.alias)
            case .rejected:
                showsCaptureRejectedNotice = true
                captureRejectionDismissTask?.cancel()
                captureRejectionDismissTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    showsCaptureRejectedNotice = false
                }
            }
        }
    }

    private func cancelCaptureIfNeeded() {
        captureRejectionDismissTask?.cancel()
        captureRejectionDismissTask = nil
        peripheralInput?.cancelCapture()
        capturingAction = nil
        showsCaptureRejectedNotice = false
    }

    // MARK: - Keyboard

    private var keyboardConnectionStatusRow: some View {
        HStack(spacing: 12) {
            Text(L10n.string("settings.keyboard.status"))
            Spacer(minLength: 0)
            Text(keyboardConnectionStatusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var keyboardConnectionStatusText: String {
        guard let peripheralInput, peripheralInput.isKeyboardConnected else {
            return L10n.string("settings.keyboard.status.disconnected")
        }
        return L10n.string("settings.keyboard.status.connected")
    }

    private var fixedKeyboardMenuRow: some View {
        HStack(spacing: 12) {
            Text(ReaderControlAction.toggleChrome.title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(L10n.string("settings.keyboard.menu_fixed"))
                .foregroundStyle(.secondary)
        }
    }

    private var keyboardFooterText: String {
        var lines = [L10n.string("settings.keyboard.dpad_note")]
        if !isKeyboardConnected {
            lines.append(L10n.string("settings.keyboard.connect_hint"))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func keyboardBindingRow(_ action: ReaderControlAction) -> some View {
        if capturingKeyboardAction == action {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(action.title)
                    Spacer(minLength: 8)
                    Text(showsKeyboardCaptureRejectedNotice
                        ? L10n.string("settings.keyboard.capture_rejected")
                        : L10n.string("settings.keyboard.capture_prompt"))
                        .font(.footnote)
                        .foregroundStyle(showsKeyboardCaptureRejectedNotice ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                HStack(spacing: 20) {
                    Button(L10n.string("common.cancel")) {
                        cancelKeyboardCaptureIfNeeded()
                    }
                    if viewModel.keyboard.bindings[action] != nil {
                        Button(L10n.string("settings.keyboard.clear_binding"), role: .destructive) {
                            cancelKeyboardCaptureIfNeeded()
                            viewModel.clearKeyboardBinding(for: action)
                        }
                    }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        } else {
            Button {
                beginKeyboardCapture(for: action)
            } label: {
                HStack(spacing: 12) {
                    Text(action.title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    keyboardBindingValueLabel(for: action)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy || !isKeyboardConnected || capturingKeyboardAction != nil)
        }
    }

    @ViewBuilder
    private func keyboardBindingValueLabel(for action: ReaderControlAction) -> some View {
        if let code = viewModel.keyboard.bindings[action] {
            let name = peripheralInput?.displayName(forKeyCode: code)
            Text(name ?? L10n.string("settings.keyboard.key_code", String(code)))
                .foregroundStyle(.secondary)
        } else {
            Text(L10n.string("settings.keyboard.unset"))
                .foregroundStyle(.secondary)
        }
    }

    private func beginKeyboardCapture(for action: ReaderControlAction) {
        guard let peripheralInput else { return }
        capturingKeyboardAction = action
        showsKeyboardCaptureRejectedNotice = false
        peripheralInput.beginKeyboardCapture { feedback in
            switch feedback {
            case let .captured(key):
                keyboardCaptureRejectionDismissTask?.cancel()
                capturingKeyboardAction = nil
                showsKeyboardCaptureRejectedNotice = false
                viewModel.bindKeyboardAction(action, toKeyCode: key.keyCode)
            case .rejected:
                showsKeyboardCaptureRejectedNotice = true
                keyboardCaptureRejectionDismissTask?.cancel()
                keyboardCaptureRejectionDismissTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    showsKeyboardCaptureRejectedNotice = false
                }
            }
        }
    }

    private func cancelKeyboardCaptureIfNeeded() {
        keyboardCaptureRejectionDismissTask?.cancel()
        keyboardCaptureRejectionDismissTask = nil
        peripheralInput?.cancelKeyboardCapture()
        capturingKeyboardAction = nil
        showsKeyboardCaptureRejectedNotice = false
    }
}
