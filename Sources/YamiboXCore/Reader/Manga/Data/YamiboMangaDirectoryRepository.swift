import Foundation

struct YamiboMangaDirectoryRepository: MangaDirectoryRepository {
    var client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        return try await MangaReaderDataSupport.mapNetworkErrors {
            guard let tid = threadID.mangaReaderTrimmedNonEmpty else {
                throw MangaReaderDataSupport.mangaDirectoryParsingFailure()
            }
            let normalizedURL = YamiboRoute.threadByID(tid: tid, page: 1, authorID: nil, reverse: false).url
            let html = try await client.fetchThreadById(tid: tid)
            try MangaReaderDataSupport.validateReadableMangaHTML(html)

            let rawTitle = MangaHTMLParser.extractThreadTitle(from: html)?.mangaReaderTrimmedNonEmpty ?? tid
            let cleanedThreadTitle = MangaTitleCleaner.cleanThreadTitle(rawTitle).mangaReaderTrimmedNonEmpty
                ?? rawTitle.mangaReaderTrimmedNonEmpty
                ?? tid
            let cleanBookName = MangaTitleCleaner.cleanBookName(rawTitle).mangaReaderTrimmedNonEmpty
                ?? cleanedThreadTitle

            let currentChapter = MangaChapter(
                tid: tid,
                rawTitle: cleanedThreadTitle,
                chapterNumber: MangaTitleCleaner.extractChapterNumber(rawTitle),
                view: 1
            )
            let mobileTagIDs = MangaHTMLParser.findTagIDsMobile(in: html)
            let tagIDs = mobileTagIDs.isEmpty ? MangaHTMLParser.findTagIDs(in: html) : mobileTagIDs
            let samePageChapters = deduplicatedSamePageChapters(
                MangaHTMLParser.extractSamePageLinks(from: html, baseURL: normalizedURL),
                excluding: tid
            )

            return MangaDirectorySeed(
                currentChapter: currentChapter,
                tagIDs: tagIDs,
                samePageChapters: samePageChapters,
                cleanBookName: cleanBookName,
                firstPostID: MangaHTMLParser.extractFirstPostID(from: html)
            )
        }
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        let normalizedTagIDs = normalizedUniqueValues(tagIDs)
        guard !normalizedTagIDs.isEmpty else { return [] }
        let allowedForumIDs = Set([allowedForumID])

        return try await MangaReaderDataSupport.mapNetworkErrors {
            var chapters: [MangaChapter] = []
            for (groupIndex, tagID) in normalizedTagIDs.enumerated() {
                try Task.checkCancellation()
                let firstHTML = try await client.fetchHTML(
                    for: .tag(id: tagID, page: 1),
                    userAgent: YamiboNetworkConfiguration.desktopTagUserAgent
                )
                try MangaReaderDataSupport.validateReadableMangaHTML(firstHTML)
                chapters.append(contentsOf: MangaHTMLParser.parseTagThreadListHTML(
                    firstHTML,
                    groupIndex: groupIndex,
                    allowedForumIDs: allowedForumIDs
                ))

                let totalPages = MangaHTMLParser.extractTotalPages(from: firstHTML)
                guard totalPages > 1 else { continue }

                for page in 2 ... totalPages {
                    try Task.checkCancellation()
                    let html = try await client.fetchHTML(
                        for: .tag(id: tagID, page: page),
                        userAgent: YamiboNetworkConfiguration.desktopTagUserAgent
                    )
                    try MangaReaderDataSupport.validateReadableMangaHTML(html)
                    let pageChapters = MangaHTMLParser.parseTagThreadListHTML(
                        html,
                        groupIndex: groupIndex,
                        allowedForumIDs: allowedForumIDs
                    )
                    guard !pageChapters.isEmpty else { continue }
                    chapters.append(contentsOf: pageChapters)
                }
            }
            return chapters
        }
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        guard let normalizedKeyword = keyword.mangaReaderTrimmedNonEmpty else { return [] }
        let normalizedForumID = forumID.mangaReaderTrimmedNonEmpty ?? "30"

        return try await MangaReaderDataSupport.mapNetworkErrors {
            try Task.checkCancellation()
            let firstHTML = try await client.fetchHTML(
                for: .search(keyword: normalizedKeyword, forumID: normalizedForumID)
            )
            try MangaReaderDataSupport.validateReadableMangaHTML(firstHTML)
            var chapters = MangaHTMLParser.parseListHTML(firstHTML)

            guard let searchID = MangaHTMLParser.extractSearchID(from: firstHTML)?.mangaReaderTrimmedNonEmpty else {
                return chapters
            }

            let totalPages = MangaHTMLParser.extractTotalPages(from: firstHTML)
            guard totalPages > 1 else { return chapters }

            for page in 2 ... totalPages {
                try Task.checkCancellation()
                let html = try await client.fetchHTML(for: .searchPage(searchID: searchID, page: page))
                try MangaReaderDataSupport.validateReadableMangaHTML(html)
                let pageChapters = MangaHTMLParser.parseListHTML(html)
                guard !pageChapters.isEmpty else { continue }
                chapters.append(contentsOf: pageChapters)
            }
            return chapters
        }
    }

    private func normalizedUniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for value in values {
            guard let trimmed = value.mangaReaderTrimmedNonEmpty,
                  seen.insert(trimmed).inserted else {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized
    }

    private func deduplicatedSamePageChapters(
        _ chapters: [MangaChapter],
        excluding currentTID: String
    ) -> [MangaChapter] {
        var seen = Set<String>()
        var deduplicated: [MangaChapter] = []
        for chapter in chapters where chapter.tid != currentTID {
            guard seen.insert(chapter.tid).inserted else { continue }
            deduplicated.append(chapter)
        }
        return deduplicated
    }
}
