import SwiftUI
import UIKit

struct YamiboWindowInputHost: UIViewRepresentable {
    let coordinator: YamiboWindowCoordinator
    let model: YamiboAppModel

    func makeUIView(context: Context) -> WindowInputProbe {
        WindowInputProbe(coordinator: coordinator, model: model)
    }

    func updateUIView(_ uiView: WindowInputProbe, context: Context) {}

    final class WindowInputProbe: UIView {
        private let coordinator: YamiboWindowCoordinator
        private let model: YamiboAppModel
        private weak var observedWindow: UIWindow?
        private var recognizer: WindowEventRecognizer?
        private var keyObserver: NSObjectProtocol?

        init(coordinator: YamiboWindowCoordinator, model: YamiboAppModel) {
            self.coordinator = coordinator
            self.model = model
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        isolated deinit { detach() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== observedWindow else { return }
            detach()
            guard let window, let windowID = model.windowID else { return }
            observedWindow = window
            coordinator.bind(window: window, windowID: windowID)
            let recognizer = WindowEventRecognizer(coordinator: coordinator, model: model)
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
            keyObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak coordinator] _ in
                MainActor.assumeIsolated { coordinator?.focus(windowID: windowID) }
            }
        }

        private func detach() {
            if let recognizer { observedWindow?.removeGestureRecognizer(recognizer) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            recognizer = nil
            keyObserver = nil
            observedWindow = nil
        }
    }
}

/// Observes the window's events without becoming first responder or consuming gestures.
private final class WindowEventRecognizer: UIGestureRecognizer {
    private let coordinator: YamiboWindowCoordinator
    private let model: YamiboAppModel

    init(coordinator: YamiboWindowCoordinator, model: YamiboAppModel) {
        self.coordinator = coordinator
        self.model = model
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        focus()
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        focus()
        route(presses, isPressed: true)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        route(presses, isPressed: false)
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        route(presses, isPressed: false)
        state = .failed
    }

    private func focus() {
        guard let window = view as? UIWindow, window.isKeyWindow, let windowID = model.windowID else { return }
        coordinator.focus(windowID: windowID)
    }

    private func route(_ presses: Set<UIPress>, isPressed: Bool) {
        guard let window = view as? UIWindow, window.isKeyWindow else { return }
        let isEditingText = Self.containsTextInputResponder(window)
        for press in presses {
            guard let key = press.key else { continue }
            model.peripheralInput.handleWindowKey(
                code: key.keyCode.rawValue,
                isPressed: isPressed,
                isEditingText: isEditingText,
                hasCommandModifier: !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
            )
        }
    }

    private static func containsTextInputResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder, view is any UIKeyInput { return true }
        return view.subviews.contains(where: containsTextInputResponder)
    }
}
