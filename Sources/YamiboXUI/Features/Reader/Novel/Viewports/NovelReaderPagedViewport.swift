import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderPagedPageSurfaceContainer<Content: View>: View {
    let settings: NovelReaderAppearanceSettings
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(readerThemeColor(for: settings.backgroundStyle, colorScheme: colorScheme))
    }
}

struct NovelReaderPagedViewportContentIdentity: Equatable {
    var structureID: UUID?
    var settings: NovelReaderAppearanceSettings
    var refererURL: URL
    var topInset: CGFloat
    var bottomInset: CGFloat

    init(
        structureID: UUID?,
        settings: NovelReaderAppearanceSettings,
        refererURL: URL,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        self.structureID = structureID
        self.settings = settings
        self.settings.isImmersiveModeEnabled = false
        self.refererURL = refererURL
        self.topInset = topInset
        self.bottomInset = bottomInset
    }
}

struct NovelReaderPagedSpreadViewportContentIdentity: Equatable {
    var usesTwoPageSpread: Bool
    var content: NovelReaderPagedViewportContentIdentity
}

#endif
