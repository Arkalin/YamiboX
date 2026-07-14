import Foundation

public enum MangaLaunchSource: String, Codable, Hashable, Sendable {
    case forum
    case favorites
    case resume
    case like
    case history
}

public struct MangaLaunchContext: Hashable, Identifiable, Sendable {
    public var originalThreadID: String
    public var chapterTID: String
    public var chapterView: Int
    public var displayTitle: String
    public var source: MangaLaunchSource
    public var initialPage: Int
    public var directoryName: String?
    public var offlineCacheFavoriteID: String?
    /// When true, this reader session must not persist reading progress,
    /// resume route, or Favorite Library recency. See Reader Preview Mode in
    /// docs/contexts/reader-navigation/CONTEXT.md.
    public var isPreview: Bool
    /// Whether the forum board this chapter belongs to currently has Smart
    /// Comic Mode on. Computed by the caller (forum routing or the
    /// favorites open-target resolver — both know the `forumID`) at launch
    /// time; the reader itself never looks this up independently
    /// (smart-comic-mode design decision #15). Every production caller
    /// stamps this explicitly from a `BoardReaderSettings` query or an
    /// existing snapshot; the init default exists solely for test-construction
    /// convenience (pluggable-reader-config R3).
    public var isSmartModeEnabled: Bool
    /// Snapshot of the forum board (fid) this chapter was launched from,
    /// scoping directory search and tag-list row filtering to that board
    /// (pluggable-reader-config decision #6). Also recorded into
    /// browsing-history rows so a later history-click can re-evaluate the
    /// board's mode with the same `isSmartComicModeEnabled(forumID:)` rule
    /// favorites use (a missing fid reads as smart-off under the strict
    /// one-rule semantics). `nil` means the launch origin had no board
    /// context (e.g. the My Likes list, R4); the reader view model's
    /// configuration construction then substitutes "30" — the single
    /// UI-side fallback point — preserving today's behavior for such
    /// launches. Like `isSmartModeEnabled` above, this is a launch-time
    /// snapshot stamped by the caller, never re-queried by the reader.
    public var forumID: String?

    public var id: String {
        originalThreadID
    }

    public init(
        originalThreadID: String,
        chapterTID: String,
        displayTitle: String,
        source: MangaLaunchSource,
        chapterView: Int = 1,
        initialPage: Int = 0,
        directoryName: String? = nil,
        offlineCacheFavoriteID: String? = nil,
        isPreview: Bool = false,
        isSmartModeEnabled: Bool = true,
        forumID: String? = nil
    ) {
        self.originalThreadID = Self.normalizedThreadID(originalThreadID, field: "originalThreadID")
        self.chapterTID = Self.normalizedThreadID(chapterTID, field: "chapterTID")
        self.chapterView = max(1, chapterView)
        self.displayTitle = displayTitle
        self.source = source
        self.initialPage = max(0, initialPage)
        self.directoryName = directoryName
        self.offlineCacheFavoriteID = offlineCacheFavoriteID?.mangaReaderTrimmedNonEmpty
        self.isPreview = isPreview
        self.isSmartModeEnabled = isSmartModeEnabled
        self.forumID = forumID?.mangaReaderTrimmedNonEmpty
    }

    private static func normalizedThreadID(_ value: String, field: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalized.isEmpty, "MangaLaunchContext requires \(field)")
        return normalized
    }
}

extension MangaLaunchContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case originalThreadID
        case chapterTID
        case chapterView
        case displayTitle
        case source
        case initialPage
        case directoryName
        case offlineCacheFavoriteID
        case isPreview
        case isSmartModeEnabled
        case forumID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalThreadID, forKey: .originalThreadID)
        try container.encode(chapterTID, forKey: .chapterTID)
        try container.encode(chapterView, forKey: .chapterView)
        try container.encode(displayTitle, forKey: .displayTitle)
        try container.encode(source, forKey: .source)
        try container.encode(initialPage, forKey: .initialPage)
        try container.encodeIfPresent(directoryName, forKey: .directoryName)
        try container.encodeIfPresent(offlineCacheFavoriteID, forKey: .offlineCacheFavoriteID)
        try container.encode(isPreview, forKey: .isPreview)
        try container.encode(isSmartModeEnabled, forKey: .isSmartModeEnabled)
        try container.encodeIfPresent(forumID, forKey: .forumID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalThreadID: try container.decode(String.self, forKey: .originalThreadID),
            chapterTID: try container.decode(String.self, forKey: .chapterTID),
            displayTitle: try container.decode(String.self, forKey: .displayTitle),
            source: try container.decode(MangaLaunchSource.self, forKey: .source),
            chapterView: try container.decodeIfPresent(Int.self, forKey: .chapterView) ?? 1,
            initialPage: try container.decodeIfPresent(Int.self, forKey: .initialPage) ?? 0,
            directoryName: try container.decodeIfPresent(String.self, forKey: .directoryName),
            offlineCacheFavoriteID: try container.decodeIfPresent(String.self, forKey: .offlineCacheFavoriteID),
            isPreview: try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false,
            // Existing persisted routes (reader-resume route store) predate
            // this field; treat them as mode-on, matching the field's own
            // default and every pre-Phase-B launch context.
            isSmartModeEnabled: try container.decodeIfPresent(Bool.self, forKey: .isSmartModeEnabled) ?? true,
            // Persisted routes written before this field existed carry no
            // board snapshot; decoding them as `nil` lets the reader view
            // model's configuration fallback substitute "30" — exactly what
            // those launches did when they were written.
            forumID: try container.decodeIfPresent(String.self, forKey: .forumID)
        )
    }
}

