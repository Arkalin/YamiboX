import Foundation

public enum ReaderSettingsTarget: Hashable, Sendable {
    case device
    case external(Resolution)

    public struct Resolution: Hashable, Sendable {
        public let width: Int
        public let height: Int

        public init?(width: Int, height: Int) {
            guard width > 0, height > 0 else { return nil }
            self.width = max(width, height)
            self.height = min(width, height)
        }

        fileprivate var key: String { "\(width)x\(height)" }
    }
}

private struct ExternalReaderProfile: Codable, Hashable, Sendable {
    var novel: NovelReaderAppearanceSettings
    var manga: MangaReaderSettings
    var trackpadSensitivity: Double?

    private enum CodingKeys: String, CodingKey { case novel, manga, trackpadSensitivity }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try novel.encode(to: container.superEncoder(forKey: .novel), includesForumFormat: false)
        try container.encode(manga, forKey: .manga)
        try container.encodeIfPresent(trackpadSensitivity, forKey: .trackpadSensitivity)
    }
}

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
    public var readerToolbarStyle: ReaderToolbarStyle
    private var externalReaderProfiles: [String: ExternalReaderProfile] = [:]

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
        readingProgress: ReadingProgressSettings = .init(),
        readerToolbarStyle: ReaderToolbarStyle = .liquidGlass
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
        self.readerToolbarStyle = readerToolbarStyle
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
        case readerToolbarStyle
        case externalReaderProfiles
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
            readingProgress: try container.decodeIfPresent(ReadingProgressSettings.self, forKey: .readingProgress) ?? .init(),
            readerToolbarStyle: try container.decodeIfPresent(ReaderToolbarStyle.self, forKey: .readerToolbarStyle) ?? .liquidGlass
        )
        externalReaderProfiles = (try? container.decode([String: ExternalReaderProfile].self, forKey: .externalReaderProfiles)) ?? [:]
    }

    public func novelSettings(for target: ReaderSettingsTarget) -> NovelReaderAppearanceSettings {
        guard case let .external(resolution) = target, let profile = externalReaderProfiles[resolution.key] else {
            return novelReader
        }
        var settings = profile.novel
        settings.forumFormat = novelReader.forumFormat
        return settings
    }

    public func mangaSettings(for target: ReaderSettingsTarget) -> MangaReaderSettings {
        guard case let .external(resolution) = target else { return manga }
        return externalReaderProfiles[resolution.key]?.manga ?? manga
    }

    public func trackpadSensitivity(for target: ReaderSettingsTarget) -> Double {
        if case let .external(resolution) = target,
           let sensitivity = externalReaderProfiles[resolution.key]?.trackpadSensitivity {
            return ExternalDisplaySettings.clampTrackpadSensitivity(sensitivity)
        }
        return system.externalDisplay.trackpadSensitivity
    }

    public mutating func initializeReaderProfile(for resolution: ReaderSettingsTarget.Resolution) {
        let sensitivity = system.externalDisplay.trackpadSensitivity
        if let profile = externalReaderProfiles[resolution.key] {
            // Older profiles already have independent reading preferences.
            if profile.trackpadSensitivity == nil {
                externalReaderProfiles[resolution.key]?.trackpadSensitivity = sensitivity
            }
        } else {
            externalReaderProfiles[resolution.key] = ExternalReaderProfile(
                novel: Self.scopedNovel(novelReader), manga: manga, trackpadSensitivity: sensitivity
            )
        }
    }

    public mutating func updateTrackpadSensitivity(_ value: Double, for target: ReaderSettingsTarget) {
        let sensitivity = ExternalDisplaySettings.clampTrackpadSensitivity(value)
        switch target {
        case .device:
            system.externalDisplay.trackpadSensitivity = sensitivity
        case let .external(resolution):
            initializeReaderProfile(for: resolution)
            externalReaderProfiles[resolution.key]?.trackpadSensitivity = sensitivity
        }
    }

    public mutating func updateNovelSettings(
        _ settings: NovelReaderAppearanceSettings, from baseline: NovelReaderAppearanceSettings, for target: ReaderSettingsTarget
    ) {
        let updated = Self.scopedNovel(settings)
        if updated != Self.scopedNovel(baseline) {
            switch target {
            case .device:
                let forumFormat = novelReader.forumFormat
                novelReader = updated
                novelReader.forumFormat = forumFormat
            case let .external(resolution):
                initializeReaderProfile(for: resolution)
                externalReaderProfiles[resolution.key]?.novel = updated
            }
        }
        novelReader.forumFormat.applyChanges(from: baseline.forumFormat, to: settings.forumFormat)
    }

    public mutating func updateMangaSettings(_ settings: MangaReaderSettings, for target: ReaderSettingsTarget) {
        switch target {
        case .device:
            manga = settings
        case let .external(resolution):
            initializeReaderProfile(for: resolution)
            externalReaderProfiles[resolution.key]?.manga = settings
        }
    }

    private static func scopedNovel(_ settings: NovelReaderAppearanceSettings) -> NovelReaderAppearanceSettings {
        var scoped = settings
        scoped.forumFormat = .init()
        scoped.resolvedFont = nil
        return scoped
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
