import SwiftUI

struct TransientMessageView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(ForumColors.brownDeep, in: Capsule())
            .shadow(color: ForumColors.brownDeep.opacity(0.22), radius: 12, x: 0, y: 6)
    }
}

private struct TransientMessageOverlayModifier: ViewModifier {
    let message: String?
    let bottomPadding: CGFloat
    let clear: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    TransientMessageView(message: message)
                        .padding(.horizontal, 24)
                        .padding(.bottom, bottomPadding)
                        .transition(
                            reduceMotion
                                ? .opacity.animation(.snappy(duration: 0.2))
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        // Transient status must never steal input from the
                        // content it floats above.
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.2), value: message)
            .task(id: message) {
                guard let message else { return }
                announceForAccessibility(message)
                try? await Task.sleep(for: displayDuration(for: message))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.snappy(duration: 0.2)) {
                        clear()
                    }
                }
            }
    }

    /// Scale on-screen time with message length so longer copy (error
    /// details) is not cut off at a fixed 3 seconds.
    private func displayDuration(for message: String) -> Duration {
        let seconds = min(max(3, Double(message.count) * 0.12), 8)
        return .seconds(seconds)
    }

    private func announceForAccessibility(_ message: String) {
#if os(iOS)
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
#endif
    }
}

extension View {
    func transientMessage(
        _ message: String?,
        bottomPadding: CGFloat = 24,
        clear: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TransientMessageOverlayModifier(
            message: message,
            bottomPadding: bottomPadding,
            clear: clear
        ))
    }
}
