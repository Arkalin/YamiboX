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
/// authentication headers, Referer, the shared bytes disk cache, and error
/// mapping.
public final class YamiboImagePipeline: YamiboImageDataLoading {
    private let engine: YamiboImageDataPipeline
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
        failureCacheDirectory: URL? = nil
    ) {
        self.init(
            engine: YamiboImageDataPipeline(),
            sessionStore: sessionStore,
            imageSession: imageSession,
            offlineImages: offlineImages,
            failureCacheDirectory: failureCacheDirectory
        )
    }

    init(
        engine: YamiboImageDataPipeline,
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil,
        failureCacheDirectory: URL? = nil
    ) {
        self.engine = engine
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
        if let scope = source.offlineScope,
           let offlineImages,
           let offline = await offlineImages.offlineImageData(url: source.url, scope: scope) {
            return offline
        }
        // Successful bytes outrank a previous failure, including bytes warmed
        // by a reader while its cover was cooling down.
        if let data = engine.cachedData(for: source) { return data }
        let client = YamiboClient(
            session: imageSession,
            credentials: context.credentials,
            handlesCookies: false
        )
        return try await coordinator.data(for: source, context: context) { [engine] in
            try await engine.data(for: source, client: client)
        }
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
        engine.cachedData(for: source)
    }

    public func clearCache() async {
        await coordinator.invalidateCovers(nil)
        engine.removeAllCachedData()
    }

    public func totalDiskUsageBytes() async -> Int {
        await engine.totalDiskUsageBytes()
    }
}
