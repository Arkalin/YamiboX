import Foundation

public protocol YamiboImageDataLoading: Sendable {
    func data(for source: YamiboImageSource) async throws -> Data
    func cachedData(for source: YamiboImageSource) -> Data?
}

/// The single entry point for loading Yamibo image bytes.
///
/// Callers describe *what* image they want with `YamiboImageSource`; the
/// pipeline owns *how* it is fetched: offline-cache lookup, current-session
/// authentication headers, Referer, the shared bytes disk cache, and error
/// mapping.
public final class YamiboImagePipeline: YamiboImageDataLoading {
    private let engine: YamiboImageDataPipeline
    private let sessionStore: any SessionStoring
    private let imageSession: URLSession
    private let offlineImages: (any YamiboOfflineImageDataProviding)?

    /// The narrow public entry point. The designated initializer with an
    /// injectable cache engine is internal; tests reach it via
    /// `@testable import`.
    public convenience init(
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil
    ) {
        self.init(
            engine: YamiboImageDataPipeline(),
            sessionStore: sessionStore,
            imageSession: imageSession,
            offlineImages: offlineImages
        )
    }

    init(
        engine: YamiboImageDataPipeline,
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil
    ) {
        self.engine = engine
        self.sessionStore = sessionStore
        self.imageSession = imageSession
        self.offlineImages = offlineImages
    }

    public func data(for source: YamiboImageSource) async throws -> Data {
        if let scope = source.offlineScope,
           let offlineImages,
           let offline = await offlineImages.offlineImageData(url: source.url, scope: scope) {
            return offline
        }

        let sessionState = await sessionStore.load()
        let client = YamiboClient(
            session: imageSession,
            credentials: sessionState.credentials
        )
        return try await engine.data(for: source, client: client)
    }

    public func cachedData(for source: YamiboImageSource) -> Data? {
        engine.cachedData(for: source)
    }

    public func clearCache() async {
        engine.removeAllCachedData()
    }

    public func totalDiskUsageBytes() async -> Int {
        await engine.totalDiskUsageBytes()
    }
}
