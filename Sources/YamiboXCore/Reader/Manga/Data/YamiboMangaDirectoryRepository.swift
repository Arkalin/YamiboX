import Foundation

struct YamiboMangaDirectoryRepository: MangaDirectoryRepository {
    var client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        return try await YamiboNetworkErrorPolicy.mappingErrors {
            guard let tid = threadID.nilIfBlank else {
                throw MangaReaderDataSupport.mangaDirectoryParsingFailure()
            }
            let normalizedURL = YamiboRoute.threadByID(tid: tid, page: 1, authorID: nil, reverse: false).url
            let html = try await client.fetchThreadById(tid: tid)
            try MangaReaderDataSupport.validateReadableMangaHTML(html)

            let facts = MangaHTMLParser.parseDirectorySeed(from: html, baseURL: normalizedURL)
            let rawTitle = facts.title?.nilIfBlank ?? tid
            let cleanedThreadTitle = MangaTitleCleaner.cleanThreadTitle(rawTitle).nilIfBlank
                ?? rawTitle.nilIfBlank
                ?? tid
            let cleanBookName = MangaTitleCleaner.cleanBookName(rawTitle).nilIfBlank
                ?? cleanedThreadTitle

            let currentChapter = MangaChapter(
                tid: tid,
                rawTitle: cleanedThreadTitle,
                chapterNumber: MangaTitleCleaner.extractChapterNumber(rawTitle),
                view: 1
            )
            let samePageChapters = deduplicatedSamePageChapters(
                facts.samePageChapters,
                excluding: tid
            )

            return MangaDirectorySeed(
                currentChapter: currentChapter,
                tagIDs: facts.tagIDs,
                samePageChapters: samePageChapters,
                cleanBookName: cleanBookName,
                firstPostID: facts.firstPostID
            )
        }
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        let normalizedTagIDs = normalizedUniqueValues(tagIDs)
        guard !normalizedTagIDs.isEmpty else { return [] }
        let allowedForumIDs = Set([allowedForumID])

        return try await YamiboNetworkErrorPolicy.mappingErrors {
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

                let totalPages = MangaHTMLParser.extractTotalPages(from: firstHTML, matching: YamiboRoute.tag(id: tagID, page: 1).url)
                guard totalPages > 1 else { continue }
                let firstPageIDs = MangaHTMLParser.parseTagThreadListHTML(firstHTML).map(\.tid).sorted()
                guard !firstPageIDs.isEmpty else { continue }
                var seenPages: Set<[String]> = [firstPageIDs]

                for page in 2 ... totalPages {
                    try Task.checkCancellation()
                    let html = try await client.fetchHTML(
                        for: .tag(id: tagID, page: page),
                        userAgent: YamiboNetworkConfiguration.desktopTagUserAgent
                    )
                    try MangaReaderDataSupport.validateReadableMangaHTML(html)
                    if let current = MangaHTMLParser.directoryCurrentPage(from: html), current != page { break }
                    // Check unfiltered rows: a valid intermediate page can consist
                    // entirely of threads from a different forum.
                    let pageIDs = MangaHTMLParser.parseTagThreadListHTML(html).map(\.tid).sorted()
                    guard !pageIDs.isEmpty, seenPages.insert(pageIDs).inserted else { break }
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
        guard let normalizedKeyword = keyword.nilIfBlank else { return [] }
        let normalizedForumID = forumID.nilIfBlank ?? "30"

        return try await YamiboNetworkErrorPolicy.mappingErrors {
            try Task.checkCancellation()
            let firstHTML = try await client.fetchHTML(
                for: .search(keyword: normalizedKeyword, forumID: normalizedForumID)
            )
            try MangaReaderDataSupport.validateReadableMangaHTML(firstHTML)
            var chapters = MangaHTMLParser.parseListHTML(firstHTML)

            guard let searchID = MangaHTMLParser.extractSearchID(from: firstHTML)?.nilIfBlank else {
                return chapters
            }

            let totalPages = MangaHTMLParser.extractTotalPages(from: firstHTML, matching: YamiboRoute.searchPage(searchID: searchID, page: 1).url)
            guard totalPages > 1 else { return chapters }
            guard !chapters.isEmpty else { return chapters }
            var seenPages: Set<[String]> = [chapters.map(\.tid).sorted()]

            for page in 2 ... totalPages {
                try Task.checkCancellation()
                let html = try await client.fetchHTML(for: .searchPage(searchID: searchID, page: page))
                try MangaReaderDataSupport.validateReadableMangaHTML(html)
                if let current = MangaHTMLParser.directoryCurrentPage(from: html), current != page { break }
                let pageChapters = MangaHTMLParser.parseListHTML(html)
                guard !pageChapters.isEmpty, seenPages.insert(pageChapters.map(\.tid).sorted()).inserted else { break }
                chapters.append(contentsOf: pageChapters)
            }
            return chapters
        }
    }

    private func normalizedUniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for value in values {
            guard let trimmed = value.nilIfBlank,
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
