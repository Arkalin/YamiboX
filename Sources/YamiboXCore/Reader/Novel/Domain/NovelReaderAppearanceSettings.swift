import Foundation

public enum ReaderBackgroundStyle: String, Codable, Hashable, CaseIterable, Sendable {
    case system
    case paper
    case mint
    case sakura
    case quiet

    public var title: String {
        switch self {
        case .system: L10n.string("reader.background.system")
        case .paper: L10n.string("reader.background.paper")
        case .mint: L10n.string("color.mint")
        case .sakura: L10n.string("reader.background.sakura")
        case .quiet: L10n.string("reader.background.quiet")
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
    public var isImmersiveModeEnabled: Bool
    public var fontScale: Double
    public var fontFamily: ReaderFontFamily
    public var lineHeightScale: Double
    public var characterSpacingScale: Double
    public var horizontalPadding: Double
    public var usesJustifiedText: Bool
    public var indentsParagraphFirstLine: Bool
    public var loadsInlineImages: Bool
    /// Retained for persisted-settings compatibility; the viewport determines spreads.
    public var showsTwoPagesInLandscapeOnPad: Bool
    public var backgroundStyle: ReaderBackgroundStyle
    public var readingMode: ReaderReadingMode
    public var pagedTurnStyle: ReaderPagedTurnStyle
    public var pageTurnDirection: ReaderPageTurnDirection
    public var translationMode: ReaderTranslationMode

    public init(
        isImmersiveModeEnabled: Bool = false,
        fontScale: Double = 1.0,
        fontFamily: ReaderFontFamily = .systemSans,
        lineHeightScale: Double = 1.45,
        characterSpacingScale: Double = 0,
        horizontalPadding: Double = 16,
        usesJustifiedText: Bool = false,
        indentsParagraphFirstLine: Bool = false,
        loadsInlineImages: Bool = true,
        showsTwoPagesInLandscapeOnPad: Bool = true,
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
        self.showsTwoPagesInLandscapeOnPad = showsTwoPagesInLandscapeOnPad
        self.backgroundStyle = backgroundStyle
        self.isImmersiveModeEnabled = isImmersiveModeEnabled
        self.readingMode = readingMode
        self.pagedTurnStyle = pagedTurnStyle
        self.pageTurnDirection = pageTurnDirection
        self.translationMode = translationMode
    }

    private enum CodingKeys: String, CodingKey {
        case isImmersiveModeEnabled
        case fontScale
        case fontFamily
        case lineHeightScale
        case characterSpacingScale
        case horizontalPadding
        case usesJustifiedText
        case indentsParagraphFirstLine
        case loadsInlineImages
        case showsTwoPagesInLandscapeOnPad
        case backgroundStyle
        case readingMode
        case pagedTurnStyle
        case pageTurnDirection
        case translationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isImmersiveModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isImmersiveModeEnabled) ?? false
        fontScale = try container.decode(Double.self, forKey: .fontScale)
        fontFamily = try container.decode(ReaderFontFamily.self, forKey: .fontFamily)
        lineHeightScale = try container.decode(Double.self, forKey: .lineHeightScale)
        characterSpacingScale = try container.decode(Double.self, forKey: .characterSpacingScale)
        horizontalPadding = try container.decode(Double.self, forKey: .horizontalPadding)
        usesJustifiedText = try container.decode(Bool.self, forKey: .usesJustifiedText)
        indentsParagraphFirstLine = try container.decode(Bool.self, forKey: .indentsParagraphFirstLine)
        loadsInlineImages = try container.decode(Bool.self, forKey: .loadsInlineImages)
        showsTwoPagesInLandscapeOnPad = try container.decode(Bool.self, forKey: .showsTwoPagesInLandscapeOnPad)
        backgroundStyle = try container.decode(ReaderBackgroundStyle.self, forKey: .backgroundStyle)
        readingMode = try container.decode(ReaderReadingMode.self, forKey: .readingMode)
        pagedTurnStyle = try container.decode(ReaderPagedTurnStyle.self, forKey: .pagedTurnStyle)
        pageTurnDirection = try container.decode(ReaderPageTurnDirection.self, forKey: .pageTurnDirection)
        translationMode = try container.decode(ReaderTranslationMode.self, forKey: .translationMode)
    }
}
