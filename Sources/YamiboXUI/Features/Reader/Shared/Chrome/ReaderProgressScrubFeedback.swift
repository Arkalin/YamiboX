import SwiftUI

#if os(iOS)
import UIKit

@MainActor
struct ReaderProgressScrubFeedback {
    private let tickGenerator = UISelectionFeedbackGenerator()
    private let startGenerator = UIImpactFeedbackGenerator(style: .light)
    private let commitGenerator = UIImpactFeedbackGenerator(style: .medium)

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
