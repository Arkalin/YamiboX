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
    var surfaces: [NovelReaderSurface]
    var settings: NovelReaderAppearanceSettings
    var refererURL: URL
    var topInset: CGFloat
    var bottomInset: CGFloat

    init(
        surfaces: [NovelReaderSurface],
        settings: NovelReaderAppearanceSettings,
        refererURL: URL,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        self.surfaces = surfaces
        self.settings = settings
        self.refererURL = refererURL
        self.topInset = topInset
        self.bottomInset = bottomInset
    }
}

struct NovelReaderPagedSpreadViewportContentIdentity: Equatable {
    var spreads: [NovelReaderPresentationSpread]
    var content: NovelReaderPagedViewportContentIdentity
}

#endif
