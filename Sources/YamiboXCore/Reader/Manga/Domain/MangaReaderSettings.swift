import Foundation

public enum MangaReadingMode: String, Codable, Hashable, CaseIterable, Sendable {
    case paged
    case vertical

    public var title: String {
        switch self {
        case .paged: L10n.string("reading_mode.paged")
        case .vertical: L10n.string("reading_mode.vertical")
        }
    }
}

public enum MangaPageTurnDirection: String, Codable, Hashable, CaseIterable, Sendable {
    case rightToLeft
    case leftToRight

    public var title: String {
        switch self {
        case .rightToLeft: L10n.string("manga.page_turn_direction.right_to_left")
        case .leftToRight: L10n.string("manga.page_turn_direction.left_to_right")
        }
    }
}

public enum MangaPageScaleMode: String, Codable, Hashable, CaseIterable, Sendable {
    case fitHeight
    case fitWidth

    public var title: String {
        switch self {
        case .fitHeight: L10n.string("manga.page_scale_mode.fit_height")
        case .fitWidth: L10n.string("manga.page_scale_mode.fit_width")
        }
    }
}

public enum MangaPageEdgeFillStyle: String, Codable, Hashable, CaseIterable, Sendable {
    case white
    case black
    case system

    public var title: String {
        switch self {
        case .white: L10n.string("manga.page_edge_fill.white")
        case .black: L10n.string("manga.page_edge_fill.black")
        case .system: L10n.string("manga.page_edge_fill.system")
        }
    }
}

public enum MangaDirectorySortOrder: String, Codable, Hashable, CaseIterable, Sendable {
    case ascending
    case descending

    public var title: String {
        switch self {
        case .ascending: L10n.string("sort.ascending")
        case .descending: L10n.string("sort.descending")
        }
    }
}

public struct MangaReaderSettings: Codable, Hashable, Sendable {
    public var isImmersiveModeEnabled: Bool
    public var readingMode: MangaReadingMode
    public var pagedTurnStyle: ReaderPagedTurnStyle
    public var pageTurnDirection: MangaPageTurnDirection
    public var pageScaleMode: MangaPageScaleMode
    public var pageEdgeFillStyle: MangaPageEdgeFillStyle
    public var brightness: Double
    public var zoomEnabled: Bool
    /// Retained for persisted-settings compatibility; the viewport determines spreads.
    public var showsTwoPagesInLandscapeOnPad: Bool
    public var ignoresTopSafeArea: Bool
    public var directorySortOrder: MangaDirectorySortOrder

    public init(
        isImmersiveModeEnabled: Bool = true,
        readingMode: MangaReadingMode = .vertical,
        pagedTurnStyle: ReaderPagedTurnStyle = .slide,
        pageTurnDirection: MangaPageTurnDirection = .leftToRight,
        pageScaleMode: MangaPageScaleMode = .fitWidth,
        pageEdgeFillStyle: MangaPageEdgeFillStyle = .black,
        brightness: Double = 1,
        zoomEnabled: Bool = true,
        showsTwoPagesInLandscapeOnPad: Bool = true,
        ignoresTopSafeArea: Bool = true,
        directorySortOrder: MangaDirectorySortOrder = .ascending
    ) {
        self.isImmersiveModeEnabled = isImmersiveModeEnabled
        self.readingMode = readingMode
        self.pagedTurnStyle = pagedTurnStyle
        self.pageTurnDirection = pageTurnDirection
        self.pageScaleMode = pageScaleMode
        self.pageEdgeFillStyle = pageEdgeFillStyle
        self.brightness = brightness
        self.zoomEnabled = zoomEnabled
        self.showsTwoPagesInLandscapeOnPad = showsTwoPagesInLandscapeOnPad
        self.ignoresTopSafeArea = ignoresTopSafeArea
        self.directorySortOrder = directorySortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case isImmersiveModeEnabled
        case readingMode
        case pagedTurnStyle
        case pageTurnDirection
        case pageScaleMode
        case pageEdgeFillStyle
        case brightness
        case zoomEnabled
        case showsTwoPagesInLandscapeOnPad
        case ignoresTopSafeArea
        case directorySortOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isImmersiveModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isImmersiveModeEnabled) ?? true
        readingMode = try container.decode(MangaReadingMode.self, forKey: .readingMode)
        pagedTurnStyle = try container.decode(ReaderPagedTurnStyle.self, forKey: .pagedTurnStyle)
        pageTurnDirection = try container.decode(MangaPageTurnDirection.self, forKey: .pageTurnDirection)
        pageScaleMode = try container.decode(MangaPageScaleMode.self, forKey: .pageScaleMode)
        pageEdgeFillStyle = try container.decode(MangaPageEdgeFillStyle.self, forKey: .pageEdgeFillStyle)
        brightness = try container.decode(Double.self, forKey: .brightness)
        zoomEnabled = try container.decode(Bool.self, forKey: .zoomEnabled)
        showsTwoPagesInLandscapeOnPad = try container.decode(Bool.self, forKey: .showsTwoPagesInLandscapeOnPad)
        ignoresTopSafeArea = try container.decode(Bool.self, forKey: .ignoresTopSafeArea)
        directorySortOrder = try container.decode(MangaDirectorySortOrder.self, forKey: .directorySortOrder)
    }
}
