import Foundation

public protocol YamiboImageDataLoading: Sendable {
    var initialLoadEpoch: UUID { get }
    func data(for source: YamiboImageSource) async throws -> Data
    func cachedData(for source: YamiboImageSource) -> Data?
    func loadContext(for source: YamiboImageSource) async throws -> YamiboImageLoadContext
    func data(for source: YamiboImageSource, context: YamiboImageLoadContext) async throws -> Data
    func isCurrent(_ context: YamiboImageLoadContext, source: YamiboImageSource) async -> Bool
    func didDecodeImage(for source: YamiboImageSource, context: YamiboImageLoadContext) async
    func loadChanges() -> AsyncStream<YamiboImageLoadRevision>
}

/// The single entry point for loading Yamibo image bytes.
///
/// Callers describe *what* image they want with `YamiboImageSource`; the
/// pipeline owns *how* it is fetched: downloads lookup, current-session
/// authentication headers, Referer, retained cover artwork, ordinary image
/// caching, and error mapping.
public final class YamiboImagePipeline: YamiboImageDataLoading {
    private let engine: YamiboImageDataPipeline
    private let coverStore: ContentCoverStore
    private let sessionStore: any SessionStoring
    private let imageSession: URLSession
    private let offlineImages: (any YamiboOfflineImageDataProviding)?
    private let coordinator: YamiboImageLoadCoordinator
    private let sessionObservation: Task<Void, Never>

    /// The narrow public entry point. The designated initializer with an
    /// injectable cache engine is internal; tests reach it via
    /// `@testable import`.
    public convenience init(
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil,
        failureCacheDirectory: URL? = nil,
        contentCoverStore: ContentCoverStore = ContentCoverStore()
    ) {
        self.init(
            engine: YamiboImageDataPipeline(),
            contentCoverStore: contentCoverStore,
            sessionStore: sessionStore,
            imageSession: imageSession,
            offlineImages: offlineImages,
            failureCacheDirectory: failureCacheDirectory
        )
    }

    init(
        engine: YamiboImageDataPipeline,
        contentCoverStore: ContentCoverStore,
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil,
        failureCacheDirectory: URL? = nil
    ) {
        self.engine = engine
        self.coverStore = contentCoverStore
        self.sessionStore = sessionStore
        self.imageSession = imageSession
        self.offlineImages = offlineImages
        let coordinator = YamiboImageLoadCoordinator(sessionStore: sessionStore,
            cacheDirectory: failureCacheDirectory ?? YamiboDatabase.defaultCacheRootDirectory().appendingPathComponent("image-load-policy"))
        self.coordinator = coordinator
        let changes = sessionStore.changes()
        sessionObservation = Task {
            await coordinator.sessionDidChange()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await coordinator.sessionDidChange()
            }
        }
    }

    deinit { sessionObservation.cancel() }

    public func loadChanges() -> AsyncStream<YamiboImageLoadRevision> { coordinator.changes() }

    public var initialLoadEpoch: UUID { coordinator.initialEpoch }

    public func loadContext(for source: YamiboImageSource) async throws -> YamiboImageLoadContext {
        try await coordinator.context(for: source)
    }

    public func isCurrent(_ context: YamiboImageLoadContext, source: YamiboImageSource) async -> Bool {
        await coordinator.isCurrent(context, source: source)
    }

    public func data(for source: YamiboImageSource) async throws -> Data {
        let context = try await loadContext(for: source)
        return try await data(for: source, context: context)
    }

    public func data(for source: YamiboImageSource, context: YamiboImageLoadContext) async throws -> Data {
        try Task.checkCancellation()
        guard await isCurrent(context, source: source) else { throw CancellationError() }
        let source = source.normalizedForLoading
        let retained = source.purpose == .cover ? try await coverStore.imageData(for: source.url) : nil
        let data: Data
        if let artwork = retained?.data {
            data = artwork
        } else if let scope = source.offlineScope,
                  let offlineImages,
                  let offline = await offlineImages.offlineImageData(url: source.url, scope: scope) {
            data = offline
        } else if let cached = engine.cachedData(for: source) {
            // Reader bytes can become retained artwork without a new request.
            data = cached
        } else if source.purpose == .content,
                  let artwork = try? await coverStore.imageData(for: source.url).data {
            // A migrated image remains usable by readers too, without making
            // the ordinary cache responsible for keeping the cover alive.
            data = artwork
        } else {
            let client = YamiboClient(
                session: imageSession,
                credentials: context.credentials,
                handlesCookies: false
            )
            data = try await coordinator.data(for: source, context: context) { [engine] in
                try await engine.data(for: source, client: client)
            }
            if source.purpose == .content, await isCurrent(context, source: source) {
                // A reader may have joined a cover's cache-free HTTP flight.
                engine.storeOrdinaryImageData(data, for: source)
            }
        }
        try Task.checkCancellation()
        guard await isCurrent(context, source: source) else { throw CancellationError() }
        if let retained, retained.data == nil {
            do {
                try await coverStore.retainImageData(data, for: source.url, generation: retained.generation)
            } catch YamiboError.invalidImageData {
                // Reader cache hits and shared flights may contain the same
                // invalid response. Do not let that copy poison the next retry.
                engine.removeCachedData(for: YamiboImageSource(url: source.url))
                throw YamiboError.invalidImageData
            }
        }
        return data
    }

    public func didDecodeImage(for source: YamiboImageSource, context: YamiboImageLoadContext) async {
        await coordinator.didDecode(source, context: context)
    }

    public func invalidateCoverFailures(for urls: Set<URL>? = nil) async {
        await coordinator.invalidateCovers(urls)
    }

    /// An explicit account transition also covers signing in again with the
    /// same auth cookie. Passive WebKit cookie notifications do not call this.
    public func prepareForAccountChange() async {
        await coordinator.invalidateCovers(nil)
    }

    public func cachedData(for source: YamiboImageSource) -> Data? {
        // Retained cover IO uses the asynchronous data entry point.
        source.purpose == .cover ? nil : engine.cachedData(for: source)
    }

    public func migrateLegacyCoverImages() async throws {
        guard engine.hasDataCache else { return }
        try await coverStore.migrateLegacyImageData(
            reading: { [engine] in engine.cachedData(for: YamiboImageSource(url: $0)) },
            removing: { [engine] in engine.removeCachedData(for: YamiboImageSource(url: $0)) }
        )
    }

    public func clearCache() async {
        await coordinator.invalidateTransientLoads()
        await engine.removeAllCachedData()
    }

    public func totalDiskUsageBytes() async -> Int {
        await engine.totalDiskUsageBytes()
    }
}
