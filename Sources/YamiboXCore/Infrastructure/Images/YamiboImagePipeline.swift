import Foundation

/// The single entry point for loading Yamibo image bytes.
///
/// Callers describe *what* image they want with `YamiboImageSource`; the
/// pipeline owns *how* it is fetched: offline-cache lookup, current-session
/// authentication headers, Referer, the shared bytes disk cache, and error
/// mapping.
/// `@unchecked Sendable`: the only mutable state is `offlineImagesStorage`,
/// and every access goes through `offlineImagesLock` (see the `offlineImages`
/// accessor); all other stored properties are immutable `let`s of Sendable or
/// internally-synchronized (URLSession) types. Keep that invariant when
/// adding state.
public final class YamiboImagePipeline: @unchecked Sendable {
    public static let shared = YamiboImagePipeline()

    private let engine: YamiboImageDataPipeline
    private let sessionStore: any SessionStoring
    private let imageSession: URLSession
    private let offlineImagesLock = NSLock()
    private nonisolated(unsafe) var offlineImagesStorage: (any YamiboOfflineImageDataProviding)?

    /// The narrow public entry point. The designated initializer with an
    /// injectable engine and session store is internal; tests reach it via
    /// `@testable import`.
    public convenience init(offlineImages: (any YamiboOfflineImageDataProviding)? = nil) {
        self.init(engine: .shared, offlineImages: offlineImages)
    }

    init(
        engine: YamiboImageDataPipeline = .shared,
        sessionStore: any SessionStoring = SessionStore(),
        imageSession: URLSession = YamiboNetworkConfiguration.makeImageSession(),
        offlineImages: (any YamiboOfflineImageDataProviding)? = nil
    ) {
        self.engine = engine
        self.sessionStore = sessionStore
        self.imageSession = imageSession
        offlineImagesStorage = offlineImages
    }

    /// Registers the offline image store once the application context exists.
    /// Sources without an `offlineScope` never consult the provider.
    public func setOfflineImageProvider(_ provider: any YamiboOfflineImageDataProviding) {
        offlineImagesLock.withLock {
            offlineImagesStorage = provider
        }
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
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
        return try await engine.data(for: source, client: client)
    }

    public func cachedData(for source: YamiboImageSource) -> Data? {
        engine.cachedData(for: source)
    }

    public func clearCache() async {
        engine.removeAllCachedData()
    }

    private var offlineImages: (any YamiboOfflineImageDataProviding)? {
        offlineImagesLock.withLock {
            offlineImagesStorage
        }
    }
}
