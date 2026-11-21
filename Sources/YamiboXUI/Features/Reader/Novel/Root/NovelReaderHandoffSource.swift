import SwiftUI
import YamiboXCore

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
