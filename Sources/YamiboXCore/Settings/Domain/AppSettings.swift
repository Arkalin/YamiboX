import Foundation

/// Thin aggregate over feature-owned settings. Each nested struct is defined
/// by the feature that owns it and uses compiler-synthesized Codable.
/// `SettingsStore` falls back to defaults when stored data fails to decode.
public struct AppSettings: Codable, Hashable, Sendable {
    public var novelReader: NovelReaderAppearanceSettings
    public var novelOfflineCache: NovelOfflineCacheSettings
    public var manga: MangaReaderSettings
    public var favorites: FavoriteLibrarySettings
    public var webBrowser: WebBrowserSettings
    public var system: SystemSettings
    public var boardReader: BoardReaderSettings
    public var appearance: AppAppearanceSettings

    public init(
        novelReader: NovelReaderAppearanceSettings = .init(),
        novelOfflineCache: NovelOfflineCacheSettings = .init(),
        manga: MangaReaderSettings = .init(),
        favorites: FavoriteLibrarySettings = .init(),
        webBrowser: WebBrowserSettings = .init(),
        system: SystemSettings = .init(),
        boardReader: BoardReaderSettings = .init(),
        appearance: AppAppearanceSettings = .init()
    ) {
        self.novelReader = novelReader
        self.novelOfflineCache = novelOfflineCache
        self.manga = manga
        self.favorites = favorites
        self.webBrowser = webBrowser
        self.system = system
        self.boardReader = boardReader
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case novelReader
        case novelOfflineCache
        case manga
        case favorites
        case webBrowser
        case system
        case boardReader
        case appearance
    }

    /// Application appearance was added after the aggregate shipped. Only that new
    /// field is optional so malformed or incomplete legacy payloads keep the
    /// store's existing all-settings fallback behavior.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            novelReader: try container.decode(NovelReaderAppearanceSettings.self, forKey: .novelReader),
            novelOfflineCache: try container.decode(NovelOfflineCacheSettings.self, forKey: .novelOfflineCache),
            manga: try container.decode(MangaReaderSettings.self, forKey: .manga),
            favorites: try container.decode(FavoriteLibrarySettings.self, forKey: .favorites),
            webBrowser: try container.decode(WebBrowserSettings.self, forKey: .webBrowser),
            system: try container.decode(SystemSettings.self, forKey: .system),
            boardReader: try container.decode(BoardReaderSettings.self, forKey: .boardReader),
            appearance: try container.decodeIfPresent(AppAppearanceSettings.self, forKey: .appearance) ?? .init()
        )
    }

    /// Convenience so callers don't need to reach through `boardReader`
    /// directly. `forumID` accepts `nil` so routing/launch-context call
    /// sites that only sometimes have a known board can pass it straight
    /// through without an extra unwrap — `nil` reports `false` like any
    /// unconfigured board.
    public func isSmartComicModeEnabled(forumID: String?) -> Bool {
        boardReader.isSmartComicModeEnabled(forumID: forumID)
    }
}
