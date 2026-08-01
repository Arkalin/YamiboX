import SwiftUI
import YamiboXCore
import UIKit
import Nuke

typealias YamiboPlatformImage = UIImage

struct YamiboRemoteImageSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    var yamiboRemoteImageSize: CGSize? {
        get { self[YamiboRemoteImageSizeKey.self] }
        set { self[YamiboRemoteImageSizeKey.self] = newValue }
    }
}

/// A decoded image ready to display, plus the original bytes when the payload
/// turned out to be animated (GIF, APNG, animated WebP/HEICS) so callers that
/// can play animations have something to play. Still images carry no bytes.
struct YamiboDisplayImage {
    var image: YamiboPlatformImage
    var animatedData: Data?

    init(container: ImageContainer) {
        self.image = container.image
        self.animatedData = container.data
    }
}

/// Makes attached bytes mean exactly one thing: this payload animates, and
/// here is what to play. The system decoder collapses every image to a single
/// still frame, and Nuke's default decoder keeps the bytes of GIFs alone — of
/// static ones too, while APNG and animated WebP keep none. So this attaches
/// what that rule misses and drops what it over-keeps.
struct YamiboAnimatedDataPreservingDecoder: ImageDecoding {
    let base: any ImageDecoding

    var isAsynchronous: Bool {
        base.isAsynchronous
    }

    func decode(_ data: Data) throws -> ImageContainer {
        var container = try base.decode(data)
        container.data = YamiboAnimatedImage.isAnimated(data) ? data : nil
        return container
    }

    func decodePartiallyDownloadedData(_ data: Data) -> ImageContainer? {
        base.decodePartiallyDownloadedData(data)
    }
}

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
            $0.makeImageDecoder = { context in
                guard let decoder = ImageDecoderRegistry.shared.decoder(for: context) else { return nil }
                return YamiboAnimatedDataPreservingDecoder(base: decoder)
            }
        }
    }

    func cachedImage(for source: YamiboImageSource) -> YamiboPlatformImage? {
        cachedDisplayImage(for: source)?.image
    }

    func image(for source: YamiboImageSource) async throws -> YamiboPlatformImage {
        try await displayImage(for: source).image
    }

    func cachedDisplayImage(for source: YamiboImageSource) -> YamiboDisplayImage? {
        pipeline.cache.cachedImage(for: nukeRequest(for: source)).map(YamiboDisplayImage.init(container:))
    }

    func displayImage(for source: YamiboImageSource) async throws -> YamiboDisplayImage {
        if let cached = cachedDisplayImage(for: source) {
            return cached
        }

        do {
            let response = try await pipeline.imageTask(with: nukeRequest(for: source)).response
            return YamiboDisplayImage(container: response.container)
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
    private let animates: Bool
    private let pipeline: YamiboUIImagePipeline
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @State private var image: YamiboPlatformImage?
    @State private var animatedData: Data?
    @State private var didFail = false
    @State private var loadedKey: String?

    init(
        source: YamiboImageSource?,
        animates: Bool = false,
        pipeline: YamiboUIImagePipeline = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.source = source
        self.animates = animates
        self.pipeline = pipeline
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            if let image {
                if let animatedData {
                    YamiboAnimatedImageView(
                        identity: taskIdentity,
                        data: animatedData,
                        posterImage: image,
                        content: content
                    )
                } else {
                    content(Image(uiImage: image))
                }
            } else if didFail {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: taskIdentity) {
            await load()
        }
        .environment(\.yamiboRemoteImageSize, image?.size)
    }

    private var taskIdentity: String {
        source?.cacheKey ?? "yamibo-image:no-source"
    }

    private func load() async {
        guard let source else {
            apply(nil)
            loadedKey = nil
            didFail = false
            return
        }
        guard loadedKey != source.cacheKey || image == nil else {
            return
        }
        if let cached = pipeline.cachedDisplayImage(for: source) {
            apply(cached)
            loadedKey = source.cacheKey
            didFail = false
            return
        }

        apply(nil)
        didFail = false
        do {
            let loaded = try await pipeline.displayImage(for: source)
            apply(loaded)
            loadedKey = source.cacheKey
            didFail = false
        } catch {
            loadedKey = source.cacheKey
            didFail = true
        }
    }

    private func apply(_ displayImage: YamiboDisplayImage?) {
        image = displayImage?.image
        animatedData = animates ? displayImage?.animatedData : nil
    }
}
