import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct ApplePencilPageTurnInteractionOverlay: UIViewRepresentable {
    var settings: ApplePencilPageTurnSettings
    var canTurnPage: Bool
    var onPageTurn: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            settings: settings,
            canTurnPage: canTurnPage,
            onPageTurn: onPageTurn
        )
    }

    func makeUIView(context: Context) -> ApplePencilPageTurnPassthroughView {
        let view = ApplePencilPageTurnPassthroughView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        interaction.isEnabled = settings.isEnabled && canTurnPage
        view.pencilInteraction = interaction
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: ApplePencilPageTurnPassthroughView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.canTurnPage = canTurnPage
        context.coordinator.onPageTurn = onPageTurn
        uiView.pencilInteraction?.isEnabled = settings.isEnabled && canTurnPage
    }

    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var settings: ApplePencilPageTurnSettings
        var canTurnPage: Bool
        var onPageTurn: (Int) -> Void

        init(
            settings: ApplePencilPageTurnSettings,
            canTurnPage: Bool,
            onPageTurn: @escaping (Int) -> Void
        ) {
            self.settings = settings
            self.canTurnPage = canTurnPage
            self.onPageTurn = onPageTurn
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            handlePageTurn(
                gesture: .doubleTap,
                preferredAction: UIPencilInteraction.preferredTapAction
            )
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            handlePageTurn(
                gesture: .doubleTap,
                preferredAction: UIPencilInteraction.preferredTapAction
            )
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            handlePageTurn(
                gesture: .squeeze,
                preferredAction: UIPencilInteraction.preferredSqueezeAction
            )
        }

        private func handlePageTurn(
            gesture: ApplePencilPageTurnGesture,
            preferredAction: UIPencilPreferredAction
        ) {
            guard settings.isEnabled, canTurnPage, preferredAction != .ignore else { return }
            onPageTurn(settings.behavior.pageDelta(for: gesture))
        }
    }
}

final class ApplePencilPageTurnPassthroughView: UIView {
    var pencilInteraction: UIPencilInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}
#endif
