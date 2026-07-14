import Foundation

public enum ReaderBackgroundStyle: String, Codable, Hashable, CaseIterable, Sendable {
    case system
    case paper
    case mint
    case sakura

    public var title: String {
        switch self {
        case .system: L10n.string("reader.background.system")
        case .paper: L10n.string("reader.background.paper")
        case .mint: L10n.string("color.mint")
        case .sakura: L10n.string("reader.background.sakura")
        }
    }
}

public enum ReaderReadingMode: String, Codable, Hashable, CaseIterable, Sendable {
    case paged
    case vertical

    public var title: String {
        switch self {
        case .paged: L10n.string("reading_mode.paged")
        case .vertical: L10n.string("reading_mode.vertical")
        }
    }
}

public enum ReaderPageTurnDirection: String, Codable, Hashable, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft

    public var title: String {
        switch self {
        case .leftToRight: L10n.string("reader.page_turn_direction.left_to_right")
        case .rightToLeft: L10n.string("reader.page_turn_direction.right_to_left")
        }
    }
}

public enum ReaderTranslationMode: String, Codable, Hashable, CaseIterable, Sendable {
    case none
    case simplified
    case traditional

    public var title: String {
        switch self {
        case .none: L10n.string("translation.original")
        case .simplified: L10n.string("translation.simplified")
        case .traditional: L10n.string("translation.traditional")
        }
    }
}

public enum ReaderFontFamily: String, Codable, Hashable, CaseIterable, Sendable {
    case systemSans
    case systemSerif
    case rounded

    public var title: String {
        switch self {
        case .systemSans: L10n.string("reader.font.system_sans")
        case .systemSerif: L10n.string("reader.font.system_serif")
        case .rounded: L10n.string("reader.font.rounded")
        }
    }

    public var paginationWidthFactor: Double {
        switch self {
        case .systemSans: 0.9
        case .systemSerif: 0.98
        case .rounded: 0.94
        }
    }
}

public struct NovelReaderAppearanceSettings: Codable, Hashable, Sendable {
    public var fontScale: Double
    public var fontFamily: ReaderFontFamily
    public var lineHeightScale: Double
    public var characterSpacingScale: Double
    public var horizontalPadding: Double
    public var usesJustifiedText: Bool
    public var indentsParagraphFirstLine: Bool
    public var loadsInlineImages: Bool
    public var showsAuthorRepliesToOthers: Bool
    public var showsTwoPagesInLandscapeOnPad: Bool
    public var backgroundStyle: ReaderBackgroundStyle
    public var readingMode: ReaderReadingMode
    public var pagedTurnStyle: ReaderPagedTurnStyle
    public var pageTurnDirection: ReaderPageTurnDirection
    public var translationMode: ReaderTranslationMode

    public init(
        fontScale: Double = 1.0,
        fontFamily: ReaderFontFamily = .systemSans,
        lineHeightScale: Double = 1.45,
        characterSpacingScale: Double = 0,
        horizontalPadding: Double = 16,
        usesJustifiedText: Bool = false,
        indentsParagraphFirstLine: Bool = false,
        loadsInlineImages: Bool = true,
        showsAuthorRepliesToOthers: Bool = true,
        showsTwoPagesInLandscapeOnPad: Bool = false,
        backgroundStyle: ReaderBackgroundStyle = .system,
        readingMode: ReaderReadingMode = .paged,
        pagedTurnStyle: ReaderPagedTurnStyle = .slide,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight,
        translationMode: ReaderTranslationMode = .none
    ) {
        self.fontScale = fontScale
        self.fontFamily = fontFamily
        self.lineHeightScale = lineHeightScale
        self.characterSpacingScale = characterSpacingScale
        self.horizontalPadding = horizontalPadding
        self.usesJustifiedText = usesJustifiedText
        self.indentsParagraphFirstLine = indentsParagraphFirstLine
        self.loadsInlineImages = loadsInlineImages
        self.showsAuthorRepliesToOthers = showsAuthorRepliesToOthers
        self.showsTwoPagesInLandscapeOnPad = showsTwoPagesInLandscapeOnPad
        self.backgroundStyle = backgroundStyle
        self.readingMode = readingMode
        self.pagedTurnStyle = pagedTurnStyle
        self.pageTurnDirection = pageTurnDirection
        self.translationMode = translationMode
    }
}
