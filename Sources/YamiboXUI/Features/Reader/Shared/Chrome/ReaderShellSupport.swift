import SwiftUI

#if os(iOS)
import UIKit

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
            DispatchQueue.main.async { [weak self, weak sampledWindow] in
                guard let self,
                      self.window === sampledWindow,
                      self.reportGeneration == generation else { return }
                self.onChange?(insets)
            }
        }
    }
}

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
