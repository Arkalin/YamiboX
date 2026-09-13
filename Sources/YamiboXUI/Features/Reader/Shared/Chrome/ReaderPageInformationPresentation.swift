import YamiboXCore

struct ReaderPageInformationPresentation: Equatable, Sendable {
    enum PageNumberStyle: Equatable, Sendable {
        case hidden
        case compact
        case full
    }

    let isPaged: Bool
    let isImmersive: Bool
    let isChromeVisible: Bool

    var isVisible: Bool { isChromeVisible || (isPaged && !isImmersive) }

    var pageNumberStyle: PageNumberStyle {
        guard isVisible else { return .hidden }
        return isChromeVisible ? .full : .compact
    }

    func chapterText(title: String, remainingPages: Int) -> String {
        guard isPaged && !isImmersive && isChromeVisible else { return title }
        return remainingPages > 0
            ? L10n.string("reader.chapter_pages_remaining", remainingPages)
            : L10n.string("reader.chapter_last_page")
    }

    func titles(work: String?, chapter: String, isRightToLeft: Bool) -> [String] {
        guard let work else { return [chapter] }
        return isRightToLeft ? [chapter, work] : [work, chapter]
    }
}
