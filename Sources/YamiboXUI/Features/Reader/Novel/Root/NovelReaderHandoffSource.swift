import SwiftUI
import YamiboXCore

/// Keep text-offset observation out of the expensive reader view hierarchy.
struct NovelReaderHandoffSource: View {
    let model: NovelReaderViewModel
    let isActive: Bool

    var body: some View {
        Color.clear
            .readingHandoff(isActive && model.novelReaderPresentation != nil
                ? YamiboHandoffPayload.novel(model.currentResumeContext) : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
