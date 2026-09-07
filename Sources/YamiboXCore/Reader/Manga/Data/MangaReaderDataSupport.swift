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

    static func mapNetworkErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            let source = LoadDiagnosticError.classificationError(error)
            guard let urlError = source as? URLError else { throw error }
            if LoadDiagnosticError.isCancellation(error) { throw error }
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw LoadDiagnosticError.mapping(error, to: YamiboError.offline)
            default:
                throw LoadDiagnosticError.mapping(error, to: YamiboError.underlying(error.localizedDescription))
            }
        }
    }
}

extension String {
    var mangaReaderTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
