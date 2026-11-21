import Foundation

enum ForumPageNavigationParser {
    enum Template {
        case forum
        case userSpace
    }

    static func parse(in document: Document, template: Template = .forum) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages: Int?
        switch template {
        case .forum:
            totalPages = HTMLTextExtractor.firstMatch(pattern: #"/\s*(\d+)\s*页"#, in: pagerText)?
                .dropFirst()
                .first
                .flatMap(Int.init)
                ?? HTMLTextExtractor.firstMatch(pattern: #"\.\.\s*(\d+)"#, in: pagerText)?
                .dropFirst()
                .first
                .flatMap(Int.init)
        case .userSpace:
            let parsedTotal = HTMLTextExtractor.firstMatch(pattern: #"共\s*(\d+)\s*页"#, in: pagerText)?
                .dropFirst()
                .first
                .flatMap(Int.init)
                ?? HTMLTextExtractor.matches(pattern: #"page=(\d+)"#, in: pager.html())
                .compactMap { $0.dropFirst().first.flatMap(Int.init) }
                .max()
            totalPages = parsedTotal.map { max($0, currentPage) }
        }

        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    }
}
