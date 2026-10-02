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

public struct NovelReaderForumFormatSettings: Codable, Hashable, Sendable {
    public var bold = true
    public var italic = true
    public var underline = true
    public var strikethrough = true
    public var textColor = true
    public var backgroundColor = true
    public var ruby = true
    public var quote = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case bold, italic, underline, strikethrough, textColor, backgroundColor, ruby, quote
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? true
        underline = try values.decodeIfPresent(Bool.self, forKey: .underline) ?? true
        strikethrough = try values.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? true
        textColor = try values.decodeIfPresent(Bool.self, forKey: .textColor) ?? true
        backgroundColor = try values.decodeIfPresent(Bool.self, forKey: .backgroundColor) ?? true
        ruby = try values.decodeIfPresent(Bool.self, forKey: .ruby) ?? true
        quote = try values.decodeIfPresent(Bool.self, forKey: .quote) ?? true
    }
}

public struct NovelReaderAppearanceSettings: Codable, Hashable, Sendable {
    public var isImmersiveModeEnabled: Bool
    public var fontScale: Double
    public var fontSelection: ReaderFontSelection
    public var resolvedFont: ReaderResolvedFont? = nil
    public var lineHeightScale: Double
    public var characterSpacingScale: Double
    public var horizontalPadding: Double
    public var usesJustifiedText: Bool
    public var indentsParagraphFirstLine: Bool
    public var loadsInlineImages: Bool
    public var forumFormat: NovelReaderForumFormatSettings
    /// Retained for persisted-settings compatibility; the viewport determines spreads.
    public var showsTwoPagesInLandscapeOnPad: Bool
    public var backgroundStyle: ReaderBackgroundStyle
    public var readingMode: ReaderReadingMode
    public var pagedTurnStyle: ReaderPagedTurnStyle
    public var pageTurnDirection: ReaderPageTurnDirection
    public var swapsPageTurnTapZones: Bool
    public var translationMode: ReaderTranslationMode

    public init(
        isImmersiveModeEnabled: Bool = false,
        fontScale: Double = 1.0,
        fontSelection: ReaderFontSelection = .standard,
        lineHeightScale: Double = 1.45,
        characterSpacingScale: Double = 0,
        horizontalPadding: Double = 16,
        usesJustifiedText: Bool = false,
        indentsParagraphFirstLine: Bool = false,
        loadsInlineImages: Bool = true,
        forumFormat: NovelReaderForumFormatSettings = .init(),
        showsTwoPagesInLandscapeOnPad: Bool = true,
        backgroundStyle: ReaderBackgroundStyle = .system,
        readingMode: ReaderReadingMode = .paged,
        pagedTurnStyle: ReaderPagedTurnStyle = .slide,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight,
        swapsPageTurnTapZones: Bool = false,
        translationMode: ReaderTranslationMode = .none
    ) {
        self.fontScale = fontScale
        self.fontSelection = fontSelection
        self.lineHeightScale = lineHeightScale
        self.characterSpacingScale = characterSpacingScale
        self.horizontalPadding = horizontalPadding
        self.usesJustifiedText = usesJustifiedText
        self.indentsParagraphFirstLine = indentsParagraphFirstLine
        self.loadsInlineImages = loadsInlineImages
        self.forumFormat = forumFormat
        self.showsTwoPagesInLandscapeOnPad = showsTwoPagesInLandscapeOnPad
        self.backgroundStyle = backgroundStyle
        self.isImmersiveModeEnabled = isImmersiveModeEnabled
        self.readingMode = readingMode
        self.pagedTurnStyle = pagedTurnStyle
        self.pageTurnDirection = pageTurnDirection
        self.swapsPageTurnTapZones = swapsPageTurnTapZones
        self.translationMode = translationMode
    }

    private enum CodingKeys: String, CodingKey {
        case isImmersiveModeEnabled
        case fontScale
        case fontSelection
        case lineHeightScale
        case characterSpacingScale
        case horizontalPadding
        case usesJustifiedText
        case indentsParagraphFirstLine
        case loadsInlineImages
        case forumFormat
        case showsTwoPagesInLandscapeOnPad
        case backgroundStyle
        case readingMode
        case pagedTurnStyle
        case pageTurnDirection
        case swapsPageTurnTapZones
        case translationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isImmersiveModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isImmersiveModeEnabled) ?? false
        fontScale = try container.decode(Double.self, forKey: .fontScale)
        if container.contains(.fontSelection) {
            fontSelection = (try? container.decode(ReaderFontSelection.self, forKey: .fontSelection)) ?? .standard
        } else {
            let legacy = try decoder.container(keyedBy: LegacyFontKeys.self)
            let name = try? legacy.decode(String.self, forKey: .fontFamily)
            fontSelection = name == "systemSerif" ? .curated(.songtiSC) : .standard
        }
        lineHeightScale = try container.decode(Double.self, forKey: .lineHeightScale)
        characterSpacingScale = try container.decode(Double.self, forKey: .characterSpacingScale)
        horizontalPadding = try container.decode(Double.self, forKey: .horizontalPadding)
        usesJustifiedText = try container.decode(Bool.self, forKey: .usesJustifiedText)
        indentsParagraphFirstLine = try container.decode(Bool.self, forKey: .indentsParagraphFirstLine)
        loadsInlineImages = try container.decode(Bool.self, forKey: .loadsInlineImages)
        forumFormat = try container.decodeIfPresent(NovelReaderForumFormatSettings.self, forKey: .forumFormat) ?? .init()
        showsTwoPagesInLandscapeOnPad = try container.decode(Bool.self, forKey: .showsTwoPagesInLandscapeOnPad)
        backgroundStyle = try container.decode(ReaderBackgroundStyle.self, forKey: .backgroundStyle)
        readingMode = try container.decode(ReaderReadingMode.self, forKey: .readingMode)
        pagedTurnStyle = try container.decode(ReaderPagedTurnStyle.self, forKey: .pagedTurnStyle)
        pageTurnDirection = try container.decode(ReaderPageTurnDirection.self, forKey: .pageTurnDirection)
        swapsPageTurnTapZones = try container.decodeIfPresent(Bool.self, forKey: .swapsPageTurnTapZones) ?? false
        translationMode = try container.decode(ReaderTranslationMode.self, forKey: .translationMode)
    }

    private enum LegacyFontKeys: String, CodingKey { case fontFamily }
}
