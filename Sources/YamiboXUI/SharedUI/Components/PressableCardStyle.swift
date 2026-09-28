import SwiftUI

/// Press feedback for card-like tappables: the card scales down slightly the
/// instant it's touched and springs back on release. List rows built as
/// `.plain` buttons get a pressed dim from the system; cards routed through
/// bare `onTapGesture` previously gave nothing back until touch-up, which
/// reads as dead. Route those through a `Button` with this style instead.
struct PressableCardStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Reduce Motion keeps the comprehension-aiding dim but drops the
            // scale movement.
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
