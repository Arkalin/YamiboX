import SwiftUI
import UIKit

/// A display-cycle acknowledgement, rather than an arbitrary navigation delay.
/// The second tick admits work only after the overlay's first committed frame.
struct NovelReaderNavigationOverlayDisplayProbe: UIViewRepresentable {
    let revision: UInt64
    let didDisplay: @MainActor (UInt64) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.configure(revision: revision, didDisplay: didDisplay)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Void) {
        view.stop()
    }

    final class ProbeView: UIView {
        private var revision: UInt64?
        private var didDisplay: (@MainActor (UInt64) -> Void)?
        private var displayLink: CADisplayLink?
        private var ticks = 0
        private var hasReported = false

        func configure(revision: UInt64, didDisplay: @escaping @MainActor (UInt64) -> Void) {
            self.didDisplay = didDisplay
            if self.revision != revision {
                stop()
                self.revision = revision
                ticks = 0
                hasReported = false
            }
            startIfAttached()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() } else { startIfAttached() }
        }

        private func startIfAttached() {
            guard window != nil, displayLink == nil, revision != nil, !hasReported else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayTick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func displayTick() {
            ticks += 1
            guard ticks >= 2, let revision else { return }
            hasReported = true
            stop()
            didDisplay?(revision)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
