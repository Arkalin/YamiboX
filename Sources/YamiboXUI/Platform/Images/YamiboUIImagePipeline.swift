import SwiftUI
import YamiboXCore
import UIKit
import Nuke
import Combine
import ImageIO
import Observation

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
    var thumbnail: YamiboImageThumbnail? = nil
    var source: YamiboImageSource? = nil
    var revision: UUID? = nil
}

/// Decode to cover the display box, not merely to fit its longest edge.
/// Round up in pixels so nearby layout sizes reuse a sharp decoded variant.
struct YamiboImageThumbnail: Hashable, Sendable {
    let widthPixels: Int
    let heightPixels: Int

    init?(pointSize: CGSize, displayScale: CGFloat) {
        let width = pointSize.width * displayScale
        let height = pointSize.height * displayScale
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width < CGFloat(Int.max / 2), height < CGFloat(Int.max / 2) else { return nil }
        widthPixels = Int(ceil(width / 32)) * 32
        heightPixels = Int(ceil(height / 32)) * 32
    }

    var options: ImageRequest.ThumbnailOptions {
        .init(size: CGSize(width: widthPixels, height: heightPixels), unit: .pixels, contentMode: .aspectFill)
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
    var preservesAnimatedData = true

    var isAsynchronous: Bool {
        base.isAsynchronous
    }

    func decode(_ data: Data) throws -> ImageContainer {
        var container = try base.decode(data)
        container.data = preservesAnimatedData && YamiboAnimatedImage.isAnimated(data) ? data : nil
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
@Observable
public final class YamiboUIImagePipeline {
    static let defaultMemoryLimitBytes = 512 * 1024 * 1024
    static let defaultEntryCostLimit = 0.25

    let dataLoader: any YamiboImageDataLoading
    private let pipeline: ImagePipeline
    private let memoryCache: ImageCache
    private let loadedImages = PassthroughSubject<(String, YamiboImageThumbnail?, YamiboDisplayImage), Never>()
    private let prefetchedBytes = PassthroughSubject<String, Never>()
    private var requestEpoch: UUID
    private var imageRevisions: [String: UUID] = [:]
    private var coverRecoveryRevisions: [String: UUID] = [:]
    @ObservationIgnored private var loadObservation: Task<Void, Never>?

    /// Recover failed views when another consumer loads the same image, even
    /// when its decoded size exceeds the memory cache's single-entry limit.
    func successfulLoads(for source: YamiboImageSource, thumbnail: YamiboImageThumbnail? = nil) -> AnyPublisher<YamiboDisplayImage, Never> {
        loadedImages
            .filter { $0.0 == source.cacheKey && $0.1 == thumbnail }
            .map { $0.2 }
            .eraseToAnyPublisher()
    }

    func prefetchedDataAvailable(for source: YamiboImageSource) -> AnyPublisher<Void, Never> {
        prefetchedBytes.filter { $0 == source.cacheKey }.map { _ in () }.eraseToAnyPublisher()
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
        self.requestEpoch = core.initialLoadEpoch
        self.memoryCache = memoryCache.cache
        self.pipeline = ImagePipeline {
            $0.imageCache = memoryCache.cache
            $0.dataCache = nil
            $0.isResumableDataEnabled = true
            $0.makeImageDecoder = { context in
                guard let decoder = ImageDecoderRegistry.shared.decoder(for: context) else { return nil }
                return YamiboAnimatedDataPreservingDecoder(base: decoder, preservesAnimatedData: context.request.thumbnail == nil)
            }
        }
        let changes = core.loadChanges()
        loadObservation = Task { [weak self] in
            for await revision in changes {
                guard !Task.isCancelled else { return }
                self?.requestEpoch = revision.epoch
                self?.imageRevisions = revision.images
                self?.coverRecoveryRevisions = revision.recoveredCovers
            }
        }
    }

    deinit { loadObservation?.cancel() }

    func requestRevision(for source: YamiboImageSource?) -> UUID {
        if let source, source.purpose == .cover, let recovery = coverRecoveryRevisions[source.cacheKey] {
            return recovery
        }
        return source.flatMap { imageRevisions[$0.cacheKey] } ?? requestEpoch
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

    func cachedDisplayImage(for source: YamiboImageSource, thumbnail: YamiboImageThumbnail? = nil) -> YamiboDisplayImage? {
        pipeline.cache.cachedImage(for: nukeRequest(for: source, thumbnail: thumbnail)).map(YamiboDisplayImage.init(container:))
    }

    /// A preview has its own decoded key, while the Core request still uses
    /// the same source/byte-cache key as the original image.
    func cachedPreviewImage(for source: YamiboImageSource, maxPixelSize: Int) -> UIImage? {
        pipeline.cache.cachedImage(for: nukeRequest(for: source, maxPixelSize: maxPixelSize))?.image
    }

    func previewImage(for source: YamiboImageSource, maxPixelSize: Int) async throws -> UIImage {
        do {
            let context = try await dataLoader.loadContext(for: source)
            let request = nukeRequest(for: source, maxPixelSize: maxPixelSize, context: context)
            let image = try await pipeline.imageTask(with: request).response.image
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            await dataLoader.didDecodeImage(for: source, context: context)
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            return image
        } catch {
            throw LoadDiagnosticError.attaching(to: Self.mapImagePipelineError(error), requestContext: source.url.absoluteString)
        }
    }

    /// Do not speculatively decode images that cannot survive the decoded
    /// cache's entry limit. The original bytes are still warmed for display;
    /// the visible page alone pays for its full-resolution decode.
    func prefetchImage(for source: YamiboImageSource) async throws {
        guard cachedImage(for: source) == nil else { return }
        let context = try await dataLoader.loadContext(for: source)
        let data = try await dataLoader.data(for: source, context: context)
        try Task.checkCancellation()
        guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
        let entryLimit = Double(memoryCache.costLimit) * min(max(memoryCache.entryCostLimit, 0), 1)
        let shouldDecode = await Task.detached(priority: .utility) {
            Self.shouldDecodeForPrefetch(data: data, entryLimit: entryLimit)
        }.value
        try Task.checkCancellation()
        guard shouldDecode else {
            // A failed inline view may be in the novel prefetch window. Let
            // that consumer retry from the warmed bytes, without decoding an
            // uncacheable original just to discard it here.
            prefetchedBytes.send(source.cacheKey)
            return
        }
        var request = nukeRequest(for: source, preparedData: data, context: context)
        request.priority = .low
        do {
            let response = try await pipeline.imageTask(with: request).response
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            await dataLoader.didDecodeImage(for: source, context: context)
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            loadedImages.send((source.cacheKey, nil, YamiboDisplayImage(container: response.container)))
            prefetchedBytes.send(source.cacheKey)
        } catch {
            throw Self.mapImagePipelineError(error)
        }
    }

    nonisolated static func shouldDecodeForPrefetch(data: Data, entryLimit: Double) -> Bool {
        guard entryLimit.isFinite, entryLimit > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return false }
        // Reserve a conservative 64-byte row alignment and RGBA output even
        // for grayscale input. Multi-frame payloads also retain their bytes.
        let depth = properties[kCGImagePropertyDepth] as? Double ?? 8
        let bytesPerPixel = max(4, 4 * ceil(depth / 8))
        let rowBytes = ceil(width * bytesPerPixel / 64) * 64
        let dataCost = CGImageSourceGetCount(source) > 1 ? Double(data.count) : 0
        return rowBytes * height + dataCost < entryLimit
    }

    func displayImage(
        for source: YamiboImageSource,
        thumbnail: YamiboImageThumbnail? = nil,
        priority: ImageRequest.Priority = .normal
    ) async throws -> YamiboDisplayImage {
        let context = try await dataLoader.loadContext(for: source)
        if let cached = cachedDisplayImage(for: source, thumbnail: thumbnail) {
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            await dataLoader.didDecodeImage(for: source, context: context)
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            loadedImages.send((source.cacheKey, thumbnail, cached))
            return cached
        }

        do {
            var request = nukeRequest(for: source, thumbnail: thumbnail, context: context)
            request.priority = priority
            let response = try await pipeline.imageTask(with: request).response
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            let image = YamiboDisplayImage(container: response.container)
            await dataLoader.didDecodeImage(for: source, context: context)
            try Task.checkCancellation()
            guard await dataLoader.isCurrent(context, source: source) else { throw CancellationError() }
            loadedImages.send((source.cacheKey, thumbnail, image))
            // Other failed variants may retry the shared bytes, but must not
            // adopt this variant's decoded image (especially a cover poster).
            prefetchedBytes.send(source.cacheKey)
            return image
        } catch {
            throw LoadDiagnosticError.attaching(to: Self.mapImagePipelineError(error), requestContext: source.url.absoluteString)
        }
    }

    /// Byte-cache clearing belongs to the Core pipeline's composition root.
    public func clearCache() async {
        pipeline.cache.removeAll()
    }

    private func nukeRequest(for source: YamiboImageSource, maxPixelSize: Int? = nil, thumbnail: YamiboImageThumbnail? = nil, preparedData: Data? = nil, context: YamiboImageLoadContext? = nil) -> ImageRequest {
        let core = dataLoader
        var imageRequest = ImageRequest(
            id: context.map { $0.requestID + (source.purpose == .cover ? ":cover" : ":content") } ?? source.cacheKey,
            data: {
                if let preparedData { return preparedData }
                if let context { return try await core.data(for: source, context: context) }
                return try await core.data(for: source)
            },
            options: [.disableDiskCache]
        )
        // Network identities include authentication, Referer and purpose;
        // successful decoded variants still reuse the original URL cache key.
        imageRequest.imageID = source.cacheKey
        // UIScreen.main is deprecated; the current trait collection carries
        // the effective display scale (falls back to 2.0 in the rare
        // unspecified case, matching every current iPhone floor).
        let displayScale = UITraitCollection.current.displayScale
        imageRequest.scale = Float(displayScale > 0 ? displayScale : 2)
        if let thumbnail {
            imageRequest.thumbnail = thumbnail.options
        } else if let maxPixelSize {
            imageRequest.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: Float(max(maxPixelSize, 1)))
        }
        return imageRequest
    }

    private static func mapImagePipelineError(_ error: any Error) -> any Error {
        guard let error = error as? ImagePipeline.Error else { return error }
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
    private let thumbnail: YamiboImageThumbnail?
    private let injectedPipeline: YamiboUIImagePipeline?
    @Environment(\.yamiboImagePipeline) private var environmentPipeline
    @Environment(\.scenePhase) private var scenePhase
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
        thumbnail: YamiboImageThumbnail? = nil,
        pipeline: YamiboUIImagePipeline? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.source = source
        self.animates = animates
        // Thumbnail decodes are static posters; playback needs original bytes.
        self.thumbnail = animates ? nil : thumbnail
        self.injectedPipeline = pipeline
        self.content = content
        self.placeholder = placeholder
        self.failure = { _ in failure() }
    }

    init(
        source: YamiboImageSource?,
        animates: Bool = false,
        thumbnail: YamiboImageThumbnail? = nil,
        pipeline: YamiboUIImagePipeline? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder retryableFailure: @escaping (@escaping () -> Void) -> Failure
    ) {
        self.source = source
        self.animates = animates
        self.thumbnail = animates ? nil : thumbnail
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, source?.purpose == .cover, didFail { attempt += 1 }
        }
        .onReceive(successfulLoads) { loaded in
            guard didFail else { return }
            apply(loaded)
            loadedIdentity = requestIdentity
            didFail = false
        }
        .onReceive(prefetchedDataAvailable) {
            guard didFail else { return }
            didFail = false
            attempt += 1
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
        return pipeline.successfulLoads(for: source, thumbnail: thumbnail)
    }

    private var prefetchedDataAvailable: AnyPublisher<Void, Never> {
        guard let source, let pipeline = injectedPipeline ?? environmentPipeline else {
            return Empty().eraseToAnyPublisher()
        }
        return pipeline.prefetchedDataAvailable(for: source)
    }

    private var taskIdentity: String {
        source?.cacheKey ?? "yamibo-image:no-source"
    }

    private var requestIdentity: YamiboUIImageRequestIdentity {
        .init(cacheKey: source?.cacheKey, pipelineID: (injectedPipeline ?? environmentPipeline).map(ObjectIdentifier.init),
              thumbnail: thumbnail, source: source, revision: (injectedPipeline ?? environmentPipeline)?.requestRevision(for: source))
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
        // Keep a cached poster visible while the pipeline validates the load
        // context and reports decoded-cache recovery to the cover policy.
        apply(pipeline.cachedDisplayImage(for: source, thumbnail: thumbnail))
        didFail = false
        do {
            let loaded = try await pipeline.displayImage(for: source, thumbnail: thumbnail)
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
