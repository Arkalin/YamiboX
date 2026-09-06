import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderPageSurface: View {
    let page: MangaReaderPageProjection
    let surfaceIdentity: MangaPagedReaderPageAppearanceIdentity
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let likedPageIDs: Set<String>
    let onLongPress: (MangaReaderPageProjection) -> Void

    @State private var loadedImage: UIImage?
    @State private var loadedPageID: String?
    @State private var loadingPageID: String?
    @State private var failedPageID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            pageEdgeFillStyle.color(for: colorScheme)

            if let image = displayedImage {
                MangaPagedReaderScaledImage(
                    image: image,
                    pageID: page.id,
                    pageScaleMode: pageScaleMode,
                    initialHorizontalAlignment: initialHorizontalAlignment,
                    pageEdgeFillStyle: pageEdgeFillStyle,
                    isSurfaceInteractionEnabled: !isChromeVisible,
                    isZoomInteractionEnabled: !isChromeVisible && zoomEnabled,
                    allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                    surfaceInteraction: surfaceInteraction,
                    onLongPress: {
                        onLongPress(page)
                    }
                )
                .id(surfaceIdentity)
            } else if loadingPageID == page.id {
                ReaderLoadStateView(
                    status: .loading,
                    tint: pageEdgeFillStyle.progressTint(for: colorScheme)
                )
            } else if failedPageID == page.id {
                ReaderLoadStateView(
                    status: .failed(title: L10n.string("image.load_failed"), message: ""),
                    retryAction: {
                        Task { await loadImage() }
                    },
                    tint: pageEdgeFillStyle.placeholderForeground(for: colorScheme)
                )
            } else {
                ReaderLoadStateView(
                    status: .loading,
                    tint: pageEdgeFillStyle.placeholderForeground(for: colorScheme)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if likedPageIDs.contains(page.id) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .task(id: page.id) { @MainActor in
            await loadImage()
        }
    }

    private var displayedImage: UIImage? {
        if let cachedImage = imageLoader.cachedImage(for: page) {
            return cachedImage
        }
        guard loadedPageID == page.id else { return nil }
        return loadedImage
    }

    @MainActor
    private func loadImage() async {
        if let cachedImage = imageLoader.cachedImage(for: page) {
            loadedImage = cachedImage
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
            return
        }

        loadingPageID = page.id
        failedPageID = nil

        do {
            let image = try await imageLoader.image(for: page)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
        } catch {
            guard !Task.isCancelled else { return }
            if loadedPageID != page.id {
                loadedImage = nil
            }
            loadingPageID = nil
            failedPageID = page.id
        }
    }
}

#endif
