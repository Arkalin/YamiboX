import Foundation
import YamiboXCore

struct UnreachedMangaDirectoryRepository: MangaDirectoryRepository {
    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        throw YamiboError.underlying("Manga directory repository is not reachable from this call site.")
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        throw YamiboError.underlying("Manga directory repository is not reachable from this call site.")
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        throw YamiboError.underlying("Manga directory repository is not reachable from this call site.")
    }
}
