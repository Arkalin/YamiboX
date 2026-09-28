import Foundation

enum MangaReaderDataSupport {
    static func validateReadableMangaHTML(_ html: String) throws {
        if MangaHTMLParser.isLoginPage(html) {
            throw YamiboError.notAuthenticated
        }
        if MangaHTMLParser.isFloodControlOrError(html) {
            throw YamiboError.floodControl
        }
    }

    static func currentMangaChapterParsingFailure() -> YamiboError {
        .parsingFailed(context: L10n.string("context.current_page_not_manga_chapter"))
    }

    static func mangaDirectoryParsingFailure() -> YamiboError {
        .parsingFailed(context: L10n.string("context.manga_directory"))
    }
}
