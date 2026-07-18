import Foundation

enum MangaReaderProjectionBuilder {
    static func build(
        from page: ForumThreadPage,
        identity: MangaReaderProjectionSourceIdentity,
        sourceFingerprint: String,
        schemaVersion: Int = MangaReaderProjection.schemaVersion,
        parserVersion: Int = MangaReaderProjection.parserVersion
    ) throws -> MangaReaderProjection {
        guard identity.authorID?.mangaReaderTrimmedNonEmpty != nil else {
            throw YamiboError.parsingFailed(context: L10n.string("parsing_context.manga_author_scope"))
        }

        let imageURLs = orderedImageURLs(from: page)
        guard !imageURLs.isEmpty else {
            throw MangaReaderDataSupport.currentMangaChapterParsingFailure()
        }

        let ownerPost = page.posts.first
        let rawTitle = page.title.mangaReaderTrimmedNonEmpty ?? identity.tid
        let chapterTitle = MangaTitleCleaner.cleanThreadTitle(rawTitle).mangaReaderTrimmedNonEmpty
            ?? rawTitle

        return MangaReaderProjection(
            tid: identity.tid,
            ownerPostID: ownerPost?.postID,
            ownerAuthorID: identity.authorID,
            ownerAuthorName: ownerPost?.author.name,
            chapterTitle: chapterTitle,
            imageURLs: imageURLs,
            sourceIdentity: identity,
            sourceFingerprint: sourceFingerprint,
            schemaVersion: schemaVersion,
            parserVersion: parserVersion
        )
    }

    private static func orderedImageURLs(from page: ForumThreadPage) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        let baseURL = YamiboRoute.threadByID(
            tid: page.thread.tid,
            page: page.pageNavigation?.currentPage ?? 1,
            authorID: nil,
            reverse: false
        ).url
        for post in page.posts {
            for image in post.images {
                guard let url = HTMLTextExtractor.absoluteURL(from: image.url, baseURL: baseURL) else {
                    continue
                }
                if seen.insert(url.absoluteString).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }
}
