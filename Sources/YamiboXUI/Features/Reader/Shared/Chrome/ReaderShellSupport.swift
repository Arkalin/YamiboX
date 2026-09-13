import SwiftUI

#if os(iOS)
import UIKit

/// Reports the safe-area insets of the window this view actually lives in —
/// scene-correct under Split View / Stage Manager. The reader shells can
/// ignore safe areas, so their own GeometryProxy insets may read zero.
/// Nil means the probe has not attached to a window or has detached.
struct ReaderWindowSafeAreaInsetsProbe: UIViewRepresentable {
    @Binding var insets: UIEdgeInsets?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = { [binding = _insets] newInsets in
            guard binding.wrappedValue != newInsets else { return }
            binding.wrappedValue = newInsets
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = { [binding = _insets] newInsets in
            guard binding.wrappedValue != newInsets else { return }
            binding.wrappedValue = newInsets
        }
    }

    final class ProbeView: UIView {
        var onChange: ((UIEdgeInsets?) -> Void)?
        private var lastReported: UIEdgeInsets?
        private weak var lastWindow: UIWindow?
        private var reportGeneration = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            let sampledWindow = window
            let insets = sampledWindow?.safeAreaInsets
            guard sampledWindow !== lastWindow || insets != lastReported else { return }
            lastWindow = sampledWindow
            lastReported = insets
            reportGeneration &+= 1
            let generation = reportGeneration
            // Defer past the current layout pass — `layoutSubviews` runs
            // inside SwiftUI's render transaction, where writing @State
            // would be a state-update-during-view-update.
            DispatchQueue.main.async { [weak self, weak sampledWindow] in
                guard let self,
                      self.window === sampledWindow,
                      self.reportGeneration == generation else { return }
                self.onChange?(insets)
            }
        }
    }
}

/// Single source of the "may Apple Pencil turn the page" rule: an iPad in
/// paged mode with readable content on screen and nothing (overlay,
/// dismissal, chrome) claiming input. Each reader feeds its own state; the
/// rule itself must not fork per reader.
enum ReaderApplePencilPageTurnGate {
    static func canTurnPage(
        isPadDevice: Bool,
        isPagedReadingMode: Bool,
        hasReadableContent: Bool,
        hasBlockingOverlay: Bool,
        isDismissing: Bool,
        isChromeVisible: Bool
    ) -> Bool {
        isPadDevice
            && isPagedReadingMode
            && hasReadableContent
            && !hasBlockingOverlay
            && !isDismissing
            && !isChromeVisible
    }
}
#endif
