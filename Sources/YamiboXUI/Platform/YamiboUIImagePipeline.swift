import SwiftUI
import YamiboXCore
import UIKit
import Nuke

typealias YamiboPlatformImage = UIImage

/// Thin UI layer over `YamiboImagePipeline`: decodes bytes into `UIImage`
/// with an in-memory cache, and offers prefetching. All byte loading —
/// offline lookup, session headers, disk cache — lives in the Core pipeline.
@MainActor
public final class YamiboUIImagePipeline {
    public static let shared = YamiboUIImagePipeline()
    static let defaultMemoryLimitBytes = 128 * 1024 * 1024

    private let core: YamiboImagePipeline
    private let pipeline: ImagePipeline
    private var prefetchingKeys = Set<String>()

    init(
        core: YamiboImagePipeline = .shared,
        memoryLimitBytes: Int = YamiboUIImagePipeline.defaultMemoryLimitBytes
    ) {
        self.core = core
        self.pipeline = ImagePipeline {
            $0.imageCache = ImageCache(costLimit: memoryLimitBytes)
            $0.dataCache = nil
            $0.isResumableDataEnabled = true
        }
    }

    func cachedImage(for source: YamiboImageSource) -> YamiboPlatformImage? {
        pipeline.cache.cachedImage(for: nukeRequest(for: source))?.image
    }

    func image(for source: YamiboImageSource) async throws -> YamiboPlatformImage {
        if let cached = cachedImage(for: source) {
            return cached
        }

        do {
            return try await pipeline.image(for: nukeRequest(for: source))
        } catch {
            throw Self.mapImagePipelineError(error)
        }
    }

    func prefetchImages(for sources: [YamiboImageSource]) {
        for source in sources {
            prefetchImage(for: source)
        }
    }

    func prefetchImage(for source: YamiboImageSource) {
        let key = source.cacheKey
        guard cachedImage(for: source) == nil,
              prefetchingKeys.insert(key).inserted else {
            return
        }

        Task { @MainActor in
            defer {
                self.prefetchingKeys.remove(key)
            }
            _ = try? await self.image(for: source)
        }
    }

    /// Clears the decoded in-memory image cache and the shared bytes disk cache.
    public func clearCache() async {
        pipeline.cache.removeAll()
        await core.clearCache()
    }

    private func nukeRequest(for source: YamiboImageSource) -> ImageRequest {
        let core = self.core
        var imageRequest = ImageRequest(
            id: source.cacheKey,
            data: { try await core.data(for: source) },
            options: [.disableDiskCache]
        )
        // UIScreen.main is deprecated; the current trait collection carries
        // the effective display scale (falls back to 2.0 in the rare
        // unspecified case, matching every current iPhone floor).
        let displayScale = UITraitCollection.current.displayScale
        imageRequest.scale = Float(displayScale > 0 ? displayScale : 2)
        return imageRequest
    }

    private static func mapImagePipelineError(_ error: ImagePipeline.Error) -> Error {
        switch error {
        case .dataLoadingFailed(let underlying):
            return underlying
        case .dataIsEmpty, .decoderNotRegistered, .decodingFailed:
            return YamiboError.invalidImageData
        default:
            return error
        }
    }
}

extension YamiboUIImagePipeline: YamiboOrdinaryImageCacheClearing {
    public func removeAllCachedData() async {
        await clearCache()
    }
}

struct YamiboRemoteImage<Content: View, Placeholder: View, Failure: View>: View {
    private let source: YamiboImageSource?
    private let pipeline: YamiboUIImagePipeline
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @State private var image: YamiboPlatformImage?
    @State private var didFail = false
    @State private var loadedKey: String?

    init(
        source: YamiboImageSource?,
        pipeline: YamiboUIImagePipeline = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.source = source
        self.pipeline = pipeline
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else if didFail {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: taskIdentity) {
            await load()
        }
    }

    private var taskIdentity: String {
        source?.cacheKey ?? "yamibo-image:no-source"
    }

    private func load() async {
        guard let source else {
            image = nil
            loadedKey = nil
            didFail = false
            return
        }
        guard loadedKey != source.cacheKey || image == nil else {
            return
        }
        if let cached = pipeline.cachedImage(for: source) {
            image = cached
            loadedKey = source.cacheKey
            didFail = false
            return
        }

        image = nil
        didFail = false
        do {
            let loaded = try await pipeline.image(for: source)
            image = loaded
            loadedKey = source.cacheKey
            didFail = false
        } catch {
            loadedKey = source.cacheKey
            didFail = true
        }
    }
}
