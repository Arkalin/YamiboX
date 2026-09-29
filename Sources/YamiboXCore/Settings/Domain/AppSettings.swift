import Foundation

/// Thin aggregate over feature-owned settings. Each nested struct is defined
/// by the feature that owns it and uses compiler-synthesized Codable.
/// `SettingsStore` falls back to defaults when stored data fails to decode.
public struct AppSettings: Codable, Hashable, Sendable {
    public var novelReader: NovelReaderAppearanceSettings
    public var novelDownload: NovelDownloadSettings
    public var manga: MangaReaderSettings
    public var favorites: FavoriteLibrarySettings
    public var webBrowser: WebBrowserSettings
    public var system: SystemSettings
    public var boardReader: BoardReaderSettings
    public var appearance: AppAppearanceSettings
    public var chapterComments: ChapterCommentFilterSettings
    public var readingProgress: ReadingProgressSettings

    public init(
        novelReader: NovelReaderAppearanceSettings = .init(),
        novelDownload: NovelDownloadSettings = .init(),
        manga: MangaReaderSettings = .init(),
        favorites: FavoriteLibrarySettings = .init(),
        webBrowser: WebBrowserSettings = .init(),
        system: SystemSettings = .init(),
        boardReader: BoardReaderSettings = .init(),
        appearance: AppAppearanceSettings = .init(),
        chapterComments: ChapterCommentFilterSettings = .init(),
        readingProgress: ReadingProgressSettings = .init()
    ) {
        self.novelReader = novelReader
        self.novelDownload = novelDownload
        self.manga = manga
        self.favorites = favorites
        self.webBrowser = webBrowser
        self.system = system
        self.boardReader = boardReader
        self.appearance = appearance
        self.chapterComments = chapterComments
        self.readingProgress = readingProgress
    }

    private enum CodingKeys: String, CodingKey {
        case novelReader
        case novelDownload
        case manga
        case favorites
        case webBrowser
        case system
        case boardReader
        case appearance
        case chapterComments
        case readingProgress
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case novelOfflineCache
    }

    /// Fields added after the aggregate shipped are optional so legacy payloads
    /// retain their other settings. Malformed original fields keep the
    /// store's existing all-settings fallback behavior.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        self.init(
            novelReader: try container.decode(NovelReaderAppearanceSettings.self, forKey: .novelReader),
            novelDownload: try container.decodeIfPresent(NovelDownloadSettings.self, forKey: .novelDownload)
                ?? legacy.decodeIfPresent(NovelDownloadSettings.self, forKey: .novelOfflineCache) ?? .init(),
            manga: try container.decode(MangaReaderSettings.self, forKey: .manga),
            favorites: try container.decode(FavoriteLibrarySettings.self, forKey: .favorites),
            webBrowser: try container.decode(WebBrowserSettings.self, forKey: .webBrowser),
            system: try container.decode(SystemSettings.self, forKey: .system),
            boardReader: try container.decode(BoardReaderSettings.self, forKey: .boardReader),
            appearance: try container.decodeIfPresent(AppAppearanceSettings.self, forKey: .appearance) ?? .init(),
            chapterComments: try container.decodeIfPresent(ChapterCommentFilterSettings.self, forKey: .chapterComments) ?? .init(),
            readingProgress: try container.decodeIfPresent(ReadingProgressSettings.self, forKey: .readingProgress) ?? .init()
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
