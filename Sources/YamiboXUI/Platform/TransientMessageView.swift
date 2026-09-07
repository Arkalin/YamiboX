import SwiftUI
import YamiboXCore

struct TransientMessageView: View {
    @Environment(\.forumTheme) private var theme
    let message: String
    var showDetails: (() -> Void)? = nil

    var body: some View {
        if let showDetails {
            Button(action: showDetails) {
                toastContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("load_failure.details"))
            .accessibilityHint(L10n.string("load_failure.details"))
            .accessibilityIdentifier("toast-failure-details")
        } else {
            toastContent
        }
    }

    private var toastContent: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            if showDetails != nil {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .background {
            Capsule()
                .fill(theme.accent)
                .allowsHitTesting(false)
        }
        .shadow(color: theme.accent.opacity(0.22), radius: 12, x: 0, y: 6)
    }
}

private struct TransientMessageOverlayModifier<Toast: View>: ViewModifier {
    let feedback: TransientFeedback?
    let bottomPadding: CGFloat
    let minimumSeconds: Double
    let horizontalPadding: CGFloat
    let animation: Animation
    let toast: (TransientFeedback, (() -> Void)?) -> Toast
    let clear: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var countdown = TransientFeedbackCountdown()
    @State private var presented: PresentedLoadFailure?
    @State private var timerRevision = UUID()
    @State private var clockOrigin = ContinuousClock.now
    @State private var isVisible = false

    private var now: Duration { clockOrigin.duration(to: .now) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isVisible, let feedback {
                    toast(feedback, feedback.details.map { details in
                        {
                            countdown.pause(id: feedback.id, now: now)
                            timerRevision = UUID()
                            presented = PresentedLoadFailure(details: details)
                        }
                    })
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(feedback.details != nil)
                }
            }
            .animation(animation, value: feedback?.id)
            .sheet(item: $presented, onDismiss: resumeCountdown) { failure in
                LoadFailureDetailsSheet(details: failure.details)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                isVisible = true
                replaceFeedback()
            }
            .onChange(of: feedback?.id) {
                guard isVisible else { return }
                replaceFeedback()
            }
            .task(id: timerRevision) {
                guard let id = countdown.id, countdown.startedAt != nil else { return }
                do { try await Task.sleep(for: countdown.remaining) } catch { return }
                guard !Task.isCancelled, feedback?.id == id, countdown.canExpire(id: id, now: now) else { return }
                clear()
            }
            .onDisappear {
                isVisible = false
                presented = nil
                countdown.replace(id: nil, duration: .zero, now: now)
                timerRevision = UUID()
                clear()
            }
    }

    private func replaceFeedback() {
        presented = nil
        countdown.replace(
            id: feedback?.id,
            duration: TransientFeedbackCountdown.duration(for: feedback?.message ?? "", minimumSeconds: minimumSeconds),
            now: now
        )
        timerRevision = UUID()
        if let feedback { announceForAccessibility(feedback.message) }
    }

    private func resumeCountdown() {
        guard let id = feedback?.id, countdown.startedAt == nil else { return }
        countdown.resume(id: id, now: now)
        timerRevision = UUID()
    }

    private func announceForAccessibility(_ message: String) {
        #if os(iOS)
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        #endif
    }
}

private struct LegacyTransientMessageModifier: ViewModifier {
    let message: String?
    let bottomPadding: CGFloat
    let clear: @MainActor () -> Void
    @State private var feedback: TransientFeedback?

    func body(content: Content) -> some View {
        content
            .transientMessage(feedback, bottomPadding: bottomPadding, clear: clear)
            .onChange(of: message, initial: true) {
                feedback = message.map { TransientFeedback(message: $0) }
            }
    }
}

private struct FailureToastModifier: ViewModifier {
    struct Input: Equatable {
        let message: String?
        let details: LoadFailureDetails?
        let eventID: UUID?
    }

    let input: Input
    let clear: @MainActor () -> Void
    @State private var feedback: TransientFeedback?

    func body(content: Content) -> some View {
        content
            .transientMessage(feedback) {
                feedback = nil
                clear()
            }
            .onChange(of: input, initial: true) {
                feedback = input.message.map { .failure($0, details: input.details) }
            }
    }
}

extension View {
    func failureToast(
        message: String?,
        details: LoadFailureDetails? = nil,
        eventID: UUID? = nil,
        clear: @escaping @MainActor () -> Void = {}
    ) -> some View {
        modifier(FailureToastModifier(
            input: .init(message: message, details: details, eventID: eventID), clear: clear
        ))
    }

    func transientMessage(
        _ feedback: TransientFeedback?,
        bottomPadding: CGFloat = 24,
        minimumSeconds: Double = 3,
        clear: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TransientMessageOverlayModifier(
            feedback: feedback, bottomPadding: bottomPadding, minimumSeconds: minimumSeconds,
            horizontalPadding: 24, animation: .snappy(duration: 0.2),
            toast: { TransientMessageView(message: $0.message, showDetails: $1) }, clear: clear
        ))
    }

    func transientFeedbackOverlay<Toast: View>(
        _ feedback: TransientFeedback?,
        bottomPadding: CGFloat,
        horizontalPadding: CGFloat,
        minimumSeconds: Double,
        animation: Animation,
        @ViewBuilder toast: @escaping (TransientFeedback, (() -> Void)?) -> Toast,
        clear: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TransientMessageOverlayModifier(
            feedback: feedback, bottomPadding: bottomPadding, minimumSeconds: minimumSeconds,
            horizontalPadding: horizontalPadding, animation: animation, toast: toast, clear: clear
        ))
    }

    func transientMessage(
        _ message: String?,
        bottomPadding: CGFloat = 24,
        clear: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(LegacyTransientMessageModifier(message: message, bottomPadding: bottomPadding, clear: clear))
    }
}
