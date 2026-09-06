import SwiftUI

#if os(iOS)
import UIKit

enum MangaSurfaceGestureRole { case pan, pinch, longPress }

@MainActor
final class MangaSurfaceGestureRegistry {
    private struct Entry {
        weak var recognizer: UIGestureRecognizer?
        let role: MangaSurfaceGestureRole
    }
    private var entries: [Entry] = []

    func register(_ recognizer: UIGestureRecognizer, role: MangaSurfaceGestureRole) {
        entries.removeAll { $0.recognizer == nil || $0.recognizer === recognizer }
        entries.append(Entry(recognizer: recognizer, role: role))
    }

    func simultaneous(_ first: UIGestureRecognizer, _ second: UIGestureRecognizer) -> Bool {
        guard let a = entries.first(where: { $0.recognizer === first })?.role,
              let b = entries.first(where: { $0.recognizer === second })?.role else { return false }
        return (a == .pan && b == .pinch) || (a == .pinch && b == .pan)
    }

    func cancel() {
        for entry in entries {
            guard let recognizer = entry.recognizer else { continue }
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }
}

@MainActor
final class MangaSurfaceGestureInput: NSObject, UIGestureRecognizerDelegate {
    let runtime: MangaSurfaceRuntime
    let registry: MangaSurfaceGestureRegistry
    let role: MangaSurfaceGestureRole
    var menuFrame: CGRect = .zero
    var onMenu: () -> Void = {}
    var instance: UUID?
    var localLocation: () -> CGPoint? = { nil }
    var localTranslation: () -> CGPoint? = { nil }
    var localVelocity: () -> CGPoint? = { nil }
    private var token: UInt64?

    init(runtime: MangaSurfaceRuntime, registry: MangaSurfaceGestureRegistry, role: MangaSurfaceGestureRole) {
        self.runtime = runtime
        self.registry = registry
        self.role = role
    }

    func makeRecognizer() -> UIGestureRecognizer {
        let recognizer: UIGestureRecognizer
        switch role {
        case .pan: recognizer = UIPanGestureRecognizer()
        case .pinch: recognizer = UIPinchGestureRecognizer()
        case .longPress:
            let longPress = UILongPressGestureRecognizer()
            longPress.minimumPressDuration = 0.45
            longPress.allowableMovement = 10
            recognizer = longPress
        }
        recognizer.delegate = self
        registry.register(recognizer, role: role)
        return recognizer
    }

    func update(_ recognizer: UIGestureRecognizer) {
        if let instance, !runtime.isMounted(instance) {
            recognizer.isEnabled = false
            return
        }
        if let token, token != runtime.generation {
            self.token = nil
            recognizer.isEnabled = false
        }
        let enabled: Bool
        switch role {
        case .pan:
            enabled = runtime.canPan
        case .pinch:
            enabled = runtime.canPinch
        case .longPress:
            enabled = runtime.imageLoaded && !menuFrame.isEmpty
        }
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if let instance, !runtime.isMounted(instance) { return false }
        switch role {
        case .pan:
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return runtime.decision(.pan(translation: size(localTranslation() ?? pan.translation(in: pan.view)),
                velocity: size(localVelocity() ?? pan.velocity(in: pan.view)))) == .panImage
        case .pinch:
            return runtime.canPinch
        case .longPress:
            runtime.setMenuFrame(menuFrame)
            return runtime.decision(.longPress(localLocation() ?? recognizer.location(in: recognizer.view))) == .menu
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        registry.simultaneous(recognizer, other)
    }

    func handle(_ recognizer: UIGestureRecognizer, localTranslation: CGPoint?) {
        if let instance, !runtime.isMounted(instance) { return }
        if role == .longPress {
            if recognizer.state == .began { onMenu() }
            return
        }
        let input: MangaContinuousInput = role == .pan ? .pan : .pinch
        if recognizer.state == .began { token = runtime.begin(input) }
        guard let token else { return }
        switch recognizer.state {
        case .began, .changed, .ended:
            if let pan = recognizer as? UIPanGestureRecognizer {
                runtime.changePan(size(localTranslation ?? pan.translation(in: pan.view)), token: token)
            } else if let pinch = recognizer as? UIPinchGestureRecognizer {
                runtime.changePinch(pinch.scale, token: token)
            }
            if recognizer.state == .ended {
                runtime.end(input, token: token, cancelled: false)
                self.token = nil
            }
        case .cancelled, .failed:
            runtime.end(input, token: token, cancelled: true)
            self.token = nil
        default: break
        }
    }

    private func size(_ point: CGPoint) -> CGSize { CGSize(width: point.x, height: point.y) }
}

struct MangaSurfaceGesture: UIGestureRecognizerRepresentable {
    let runtime: MangaSurfaceRuntime
    let registry: MangaSurfaceGestureRegistry
    let role: MangaSurfaceGestureRole
    var menuFrame: CGRect = .zero
    var onMenu: () -> Void = {}
    var instance: UUID?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> MangaSurfaceGestureInput {
        MangaSurfaceGestureInput(runtime: runtime, registry: registry, role: role)
    }

    func makeUIGestureRecognizer(context: Context) -> UIGestureRecognizer {
        let recognizer = context.coordinator.makeRecognizer()
        updateUIGestureRecognizer(recognizer, context: context)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIGestureRecognizer, context: Context) {
        context.coordinator.menuFrame = menuFrame
        context.coordinator.onMenu = onMenu
        context.coordinator.instance = instance
        let converter = context.converter
        context.coordinator.localLocation = { converter.localLocation }
        context.coordinator.localTranslation = { converter.localTranslation }
        context.coordinator.localVelocity = { converter.localVelocity }
        context.coordinator.update(recognizer)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIGestureRecognizer, context: Context) {
        context.coordinator.handle(recognizer, localTranslation: context.converter.localTranslation)
    }
}
#endif
