import Foundation
import YamiboXCore

/// `editDraft(for:currentTID:)` is the only pure helper this view model needs
/// off `MangaDirectoryWorkflow` outside an update/reload, and it never touches
/// the repository — this placeholder keeps those synchronous call sites from
/// having to await the real repository factory just to satisfy the
/// initializer.
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
