import SwiftUI

#if os(iOS)
import UIKit

/// Window-level metrics shared by both reader shells — previously verbatim
/// per-reader copies that had to be kept in sync by hand.
enum ReaderShellMetrics {
    /// Safe-area insets of the key window. Backstop only: it seeds the
    /// shells' inset state for the frames before
    /// `ReaderWindowSafeAreaInsetsProbe` has a window to read from. Being a
    /// key-window scan it can pick the wrong window under Split View /
    /// Stage Manager, which is why the probe's scene-local value replaces
    /// it as soon as the reader is attached.
    @MainActor
    static var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }
}

/// Reports the safe-area insets of the window this view actually lives in —
/// scene-correct under Split View / Stage Manager, unlike the key-window
/// scan above. The reader shells sit behind `.ignoresSafeArea()`, so their
/// own GeometryProxy insets read zero and the window is the only honest
/// source; this probe replaces reaching for a global to find one.
struct ReaderWindowSafeAreaInsetsProbe: UIViewRepresentable {
    @Binding var insets: UIEdgeInsets

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
        var onChange: ((UIEdgeInsets) -> Void)?
        private var lastReported: UIEdgeInsets?

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
            guard let window else { return }
            let insets = window.safeAreaInsets
            guard insets != lastReported else { return }
            lastReported = insets
            // Defer past the current layout pass — `layoutSubviews` runs
            // inside SwiftUI's render transaction, where writing @State
            // would be a state-update-during-view-update.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(insets)
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
