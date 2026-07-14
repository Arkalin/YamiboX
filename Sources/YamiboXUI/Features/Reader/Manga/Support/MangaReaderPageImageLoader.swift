import Foundation
import YamiboXCore

#if os(iOS)
import UIKit

/// Page-keyed image access for the manga reader viewports: maps a page
/// projection to its `YamiboImageSource` and forwards to the UI pipeline.
@MainActor
final class MangaReaderPageImageLoader {
    private let imageSource: (MangaReaderPageProjection) -> YamiboImageSource
    private let uiImagePipeline: YamiboUIImagePipeline

    init(
        imageSource: @escaping (MangaReaderPageProjection) -> YamiboImageSource,
        uiImagePipeline: YamiboUIImagePipeline = .shared
    ) {
        self.imageSource = imageSource
        self.uiImagePipeline = uiImagePipeline
    }

    func cachedImage(for page: MangaReaderPageProjection) -> UIImage? {
        uiImagePipeline.cachedImage(for: imageSource(page))
    }

    func prefetchImages(for pages: [MangaReaderPageProjection]) {
        uiImagePipeline.prefetchImages(for: pages.map(imageSource))
    }

    func image(for page: MangaReaderPageProjection) async throws -> UIImage {
        do {
            return try await uiImagePipeline.image(for: imageSource(page))
        } catch {
            if !(error is CancellationError) {
                YamiboLog.reader.warning("Failed to load manga page image: \(error.localizedDescription)")
            }
            throw error
        }
    }
}

extension MangaReaderPageProjection {
    func mangaReaderImageSource(offlineScope: YamiboImageOfflineScope?) -> YamiboImageSource {
        YamiboImageSource(
            url: imageURL,
            refererPageURL: mangaReaderRefererURL,
            offlineScope: offlineScope
        )
    }

    var mangaReaderRefererURL: URL {
        YamiboRoute.threadByID(
            tid: sourceIdentity.tid,
            page: sourceIdentity.view,
            authorID: sourceIdentity.authorID,
            reverse: false
        ).url
    }
}
#endif
