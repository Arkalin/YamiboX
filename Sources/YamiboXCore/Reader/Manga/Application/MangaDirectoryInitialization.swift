import Foundation

enum MangaDirectoryInitialization {
    static func directory(from seed: MangaDirectorySeed) -> MangaDirectory {
        let tagIDs = normalizedTagIDs(seed.tagIDs)
        let chapters = deduplicatedChapters(current: seed.currentChapter, samePage: seed.samePageChapters)
        let cleanBookName = normalizedBookName(seed)
        let strategy: MangaDirectoryStrategy
        let sourceKey: String

        if !tagIDs.isEmpty {
            strategy = .tag
            sourceKey = tagIDs.joined(separator: ",")
        } else if chapters.count > 1 {
            strategy = .links
            sourceKey = seed.firstPostID ?? cleanBookName
        } else {
            strategy = .pendingSearch
            sourceKey = cleanBookName
        }

        return MangaDirectory(
            cleanBookName: cleanBookName,
            strategy: strategy,
            sourceKey: sourceKey,
            chapters: chapters
        )
    }

    private static func normalizedTagIDs(_ tagIDs: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for tagID in tagIDs {
            let value = tagID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            normalized.append(value)
        }

        return normalized
    }

    private static func deduplicatedChapters(
        current: MangaChapter,
        samePage: [MangaChapter]
    ) -> [MangaChapter] {
        var seen: Set<String> = []
        var chapters: [MangaChapter] = []
        chapters.reserveCapacity(1 + samePage.count)

        for chapter in [current] + samePage where seen.insert(chapter.tid).inserted {
            chapters.append(chapter)
        }

        return MangaDirectoryMerge.mergeAndSort([], chapters)
    }

    private static func normalizedBookName(_ seed: MangaDirectorySeed) -> String {
        let cleanBookName = seed.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBookName.isEmpty {
            return cleanBookName
        }

        let rawTitle = seed.currentChapter.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawTitle.isEmpty ? seed.currentChapter.tid : rawTitle
    }
}
