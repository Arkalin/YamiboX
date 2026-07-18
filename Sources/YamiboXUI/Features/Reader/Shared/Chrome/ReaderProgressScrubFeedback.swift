import SwiftUI

#if os(iOS)
import UIKit

/// The scrub gesture's haptic engine shared by both readers' bottom chrome:
/// which generator fires for which `ReaderProgressScrubHaptic`, and the
/// fire-then-re-prepare cadence, must stay identical across readers — the
/// two chrome views previously each owned a verbatim copy of this mapping.
@MainActor
struct ReaderProgressScrubFeedback {
    private let tickGenerator = UISelectionFeedbackGenerator()
    private let startGenerator = UIImpactFeedbackGenerator(style: .light)
    private let commitGenerator = UIImpactFeedbackGenerator(style: .medium)

    /// Spins the Taptic Engine up ahead of the first haptic — call on
    /// appearance and on scrub touch-down so the opening tick lands crisply.
    func prepare() {
        startGenerator.prepare()
        tickGenerator.prepare()
        commitGenerator.prepare()
    }

    func trigger(_ haptics: [ReaderProgressScrubHaptic]) {
        for haptic in haptics {
            switch haptic {
            case .start:
                startGenerator.impactOccurred()
                startGenerator.prepare()
                tickGenerator.prepare()
            case .chapterTick:
                tickGenerator.selectionChanged()
                tickGenerator.prepare()
            case .commit:
                commitGenerator.impactOccurred()
                commitGenerator.prepare()
            }
        }
    }
}
#endif
