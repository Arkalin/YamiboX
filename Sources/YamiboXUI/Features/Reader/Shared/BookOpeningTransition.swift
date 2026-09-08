import SwiftUI

/// Each visible book owns a namespace, so the same favorite in a collection
/// and the library beneath it cannot compete as the return destination.
struct BookOpeningTransition: Equatable {
    let namespace: Namespace.ID

    static let sourceID = "book-cover"
}

struct BookOpeningButtonStyle: PrimitiveButtonStyle {
    enum PressTarget {
        case label
        case cover
    }

    var pressTarget: PressTarget = .label

    func makeBody(configuration: Configuration) -> some View {
        BookOpeningButton(configuration: configuration, pressTarget: pressTarget)
    }
}

struct BookOpeningPressFeedback {
    static let compressionDuration: Duration = .milliseconds(120)

    private var pressedAt: ContinuousClock.Instant?
    private(set) var activationDelay: Duration?

    var isActivating: Bool { activationDelay != nil }

    mutating func pressChanged(_ isPressed: Bool, now: ContinuousClock.Instant = .now) {
        guard !isActivating else { return }
        pressedAt = isPressed ? now : nil
    }

    mutating func activate(reduceMotion: Bool, now: ContinuousClock.Instant = .now) {
        guard !isActivating else { return }
        // Scroll views can coalesce the entire quick press. Complete the missing
        // compression before navigation rather than requiring a sustained touch.
        let elapsed = pressedAt.map { $0.duration(to: now) } ?? .zero
        activationDelay = reduceMotion ? .zero : max(.zero, Self.compressionDuration - elapsed)
    }

    mutating func reset() {
        pressedAt = nil
        activationDelay = nil
    }
}

private struct BookOpeningButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let pressTarget: BookOpeningButtonStyle.PressTarget

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback = BookOpeningPressFeedback()

    var body: some View {
        Button(role: configuration.role) {
            guard isEnabled else { return }
            feedback.activate(reduceMotion: reduceMotion)
        } label: {
            configuration.label
        }
        .buttonStyle(BookOpeningPressStyle(
            isActivating: feedback.isActivating,
            pressTarget: pressTarget,
            pressChanged: { feedback.pressChanged($0) }
        ))
        .task(id: feedback.activationDelay) {
            guard let delay = feedback.activationDelay else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, isEnabled, feedback.isActivating else { return }
            configuration.trigger()
            feedback.reset()
        }
        .onChange(of: isEnabled) {
            if !isEnabled { feedback.reset() }
        }
        .onDisappear { feedback.reset() }
    }
}

private struct BookOpeningPressStyle: ButtonStyle {
    let isActivating: Bool
    let pressTarget: BookOpeningButtonStyle.PressTarget
    let pressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed || isActivating
        configuration.label
            .modifier(BookOpeningPressEffect(isPressed: pressTarget == .label && isPressed))
            .environment(\.isBookOpeningCoverPressed, pressTarget == .cover && isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                pressChanged(pressed)
            }
    }
}

extension EnvironmentValues {
    @Entry var isBookOpeningCoverPressed = false
}

struct BookOpeningCoverPressEffect: ViewModifier {
    @Environment(\.isBookOpeningCoverPressed) private var isPressed

    func body(content: Content) -> some View {
        content.modifier(BookOpeningPressEffect(isPressed: isPressed))
    }
}

private struct BookOpeningPressEffect: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isPressed ? 0.94 : 1)
            .animation(
                reduceMotion || isPressed
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.28, dampingFraction: 1),
                value: isPressed
            )
    }
}

/// The source is fixed for a presentation, including its closing animation.
/// The system owns the spring, source cross-fade, interactive cancellation,
/// offscreen-source fallback, and Reduce Motion behavior in both directions.
struct BookOpeningDestination<Content: View>: View {
    let source: BookOpeningTransition?
    @ViewBuilder let content: Content

    var body: some View {
        if let source {
            content.navigationTransition(.zoom(sourceID: BookOpeningTransition.sourceID, in: source.namespace))
        } else {
            content
        }
    }
}
