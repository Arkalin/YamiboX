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
    public var readingMode: MangaReadingMode
    public var pagedTurnStyle: ReaderPagedTurnStyle
    public var pageTurnDirection: MangaPageTurnDirection
    public var pageScaleMode: MangaPageScaleMode
    public var pageEdgeFillStyle: MangaPageEdgeFillStyle
    public var brightness: Double
    public var zoomEnabled: Bool
    public var showsTwoPagesInLandscapeOnPad: Bool
    public var ignoresTopSafeArea: Bool
    public var directorySortOrder: MangaDirectorySortOrder

    public init(
        readingMode: MangaReadingMode = .vertical,
        pagedTurnStyle: ReaderPagedTurnStyle = .slide,
        pageTurnDirection: MangaPageTurnDirection = .leftToRight,
        pageScaleMode: MangaPageScaleMode = .fitWidth,
        pageEdgeFillStyle: MangaPageEdgeFillStyle = .black,
        brightness: Double = 1,
        zoomEnabled: Bool = true,
        showsTwoPagesInLandscapeOnPad: Bool = false,
        ignoresTopSafeArea: Bool = true,
        directorySortOrder: MangaDirectorySortOrder = .ascending
    ) {
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
}
