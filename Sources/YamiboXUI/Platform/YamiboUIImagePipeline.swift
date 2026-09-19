import SwiftUI
import YamiboXCore
import UIKit
import Nuke
import Combine

typealias YamiboPlatformImage = UIImage

extension EnvironmentValues {
    @Entry var yamiboRemoteImageSize: CGSize? = nil
    @Entry var yamiboImagePipeline: YamiboUIImagePipeline? = nil
}

/// Shared by the app's decoded pipeline and its storage-settings commands.
public final class YamiboUIImageMemoryCache: YamiboOrdinaryImageCacheClearing {
    fileprivate let cache: ImageCache

    public init(memoryLimitBytes: Int = 512 * 1024 * 1024, entryCostLimit: Double = 0.25) {
        cache = ImageCache(costLimit: memoryLimitBytes)
        cache.entryCostLimit = entryCostLimit
    }

    public func removeAllCachedData() async {
        cache.removeAll()
    }

    public func totalDiskUsageBytes() async -> Int { 0 }
}

enum YamiboUIImageLoadingError: Error {
    case missingPipeline
}

struct YamiboUIImageRequestIdentity: Hashable {
    let cacheKey: String?
    let pipelineID: ObjectIdentifier?
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
/// with an in-memory cache. All byte loading —
/// offline lookup, session headers, disk cache — lives in the Core pipeline.
@MainActor
public final class YamiboUIImagePipeline {
    static let defaultMemoryLimitBytes = 512 * 1024 * 1024
    static let defaultEntryCostLimit = 0.25

    let dataLoader: any YamiboImageDataLoading
    private let pipeline: ImagePipeline
    private let loadedImages = PassthroughSubject<(String, YamiboDisplayImage), Never>()

    /// Recover failed views when another consumer loads the same image, even
    /// when its decoded size exceeds the memory cache's single-entry limit.
    func successfulLoads(for source: YamiboImageSource) -> AnyPublisher<YamiboDisplayImage, Never> {
        loadedImages
            .filter { $0.0 == source.cacheKey }
            .map { $0.1 }
            .eraseToAnyPublisher()
    }

    convenience init(
        core: any YamiboImageDataLoading,
        memoryLimitBytes: Int = YamiboUIImagePipeline.defaultMemoryLimitBytes,
        entryCostLimit: Double = YamiboUIImagePipeline.defaultEntryCostLimit
    ) {
        self.init(core: core, memoryCache: YamiboUIImageMemoryCache(
            memoryLimitBytes: memoryLimitBytes,
            entryCostLimit: entryCostLimit
        ))
    }

    public init(core: any YamiboImageDataLoading, memoryCache: YamiboUIImageMemoryCache) {
        self.dataLoader = core
        self.pipeline = ImagePipeline {
            $0.imageCache = memoryCache.cache
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

    func image(
        for source: YamiboImageSource,
        priority: ImageRequest.Priority = .normal
    ) async throws -> YamiboPlatformImage {
        try await displayImage(for: source, priority: priority).image
    }

    func cachedDisplayImage(for source: YamiboImageSource) -> YamiboDisplayImage? {
        pipeline.cache.cachedImage(for: nukeRequest(for: source)).map(YamiboDisplayImage.init(container:))
    }

    func displayImage(
        for source: YamiboImageSource,
        priority: ImageRequest.Priority = .normal
    ) async throws -> YamiboDisplayImage {
        if let cached = cachedDisplayImage(for: source) {
            loadedImages.send((source.cacheKey, cached))
            return cached
        }

        do {
            var request = nukeRequest(for: source)
            request.priority = priority
            let response = try await pipeline.imageTask(with: request).response
            let image = YamiboDisplayImage(container: response.container)
            loadedImages.send((source.cacheKey, image))
            return image
        } catch {
            throw LoadDiagnosticError.attaching(to: Self.mapImagePipelineError(error), requestContext: source.url.absoluteString)
        }
    }

    /// Byte-cache clearing belongs to the Core pipeline's composition root.
    public func clearCache() async {
        pipeline.cache.removeAll()
    }

    private func nukeRequest(for source: YamiboImageSource) -> ImageRequest {
        let core = dataLoader
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
            return LoadDiagnosticError.mapping(error, to: YamiboError.invalidImageData)
        default:
            return error
        }
    }
}

struct YamiboRemoteImage<Content: View, Placeholder: View, Failure: View>: View {
    private let source: YamiboImageSource?
    private let animates: Bool
    private let injectedPipeline: YamiboUIImagePipeline?
    @Environment(\.yamiboImagePipeline) private var environmentPipeline
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let failure: (@escaping () -> Void) -> Failure

    @State private var image: YamiboPlatformImage?
    @State private var animatedData: Data?
    @State private var didFail = false
    @State private var loadedIdentity: YamiboUIImageRequestIdentity?
    @State private var attempt = 0

    init(
        source: YamiboImageSource?,
        animates: Bool = false,
        pipeline: YamiboUIImagePipeline? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.source = source
        self.animates = animates
        self.injectedPipeline = pipeline
        self.content = content
        self.placeholder = placeholder
        self.failure = { _ in failure() }
    }

    init(
        source: YamiboImageSource?,
        animates: Bool = false,
        pipeline: YamiboUIImagePipeline? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder retryableFailure: @escaping (@escaping () -> Void) -> Failure
    ) {
        self.source = source
        self.animates = animates
        self.injectedPipeline = pipeline
        self.content = content
        self.placeholder = placeholder
        self.failure = retryableFailure
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
                failure {
                    didFail = false
                    attempt += 1
                }
            } else {
                placeholder()
            }
        }
        .task(id: LoadIdentity(request: requestIdentity, attempt: attempt)) {
            await load()
        }
        .onReceive(successfulLoads) { loaded in
            guard didFail else { return }
            apply(loaded)
            loadedIdentity = requestIdentity
            didFail = false
        }
        .environment(\.yamiboRemoteImageSize, image?.size)
    }

    private struct LoadIdentity: Hashable {
        let request: YamiboUIImageRequestIdentity
        let attempt: Int
    }

    private var successfulLoads: AnyPublisher<YamiboDisplayImage, Never> {
        guard let source, let pipeline = injectedPipeline ?? environmentPipeline else {
            return Empty().eraseToAnyPublisher()
        }
        return pipeline.successfulLoads(for: source)
    }

    private var taskIdentity: String {
        source?.cacheKey ?? "yamibo-image:no-source"
    }

    private var requestIdentity: YamiboUIImageRequestIdentity {
        .init(cacheKey: source?.cacheKey, pipelineID: (injectedPipeline ?? environmentPipeline).map(ObjectIdentifier.init))
    }

    private func load() async {
        guard let source else {
            apply(nil)
            loadedIdentity = nil
            didFail = false
            return
        }
        let identity = requestIdentity
        guard loadedIdentity != identity || image == nil else {
            return
        }
        guard let pipeline = injectedPipeline ?? environmentPipeline else {
            apply(nil)
            didFail = true
            return
        }
        if let cached = pipeline.cachedDisplayImage(for: source) {
            apply(cached)
            loadedIdentity = identity
            didFail = false
            return
        }

        apply(nil)
        didFail = false
        do {
            let loaded = try await pipeline.displayImage(for: source)
            guard !Task.isCancelled else { return }
            apply(loaded)
            loadedIdentity = identity
            didFail = false
        } catch {
            guard !Task.isCancelled else { return }
            loadedIdentity = identity
            didFail = true
        }
    }

    private func apply(_ displayImage: YamiboDisplayImage?) {
        image = displayImage?.image
        animatedData = animates ? displayImage?.animatedData : nil
    }
}
