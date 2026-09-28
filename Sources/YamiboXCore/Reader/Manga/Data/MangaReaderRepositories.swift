import Foundation

public struct MangaReaderProjectionRequest: Codable, Hashable, Sendable {
    public var threadID: String
    public var view: Int
    public var authorID: String?
    public var offlineOwnerName: String?

    public init(threadID: String, view: Int = 1, authorID: String? = nil, offlineOwnerName: String? = nil) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "MangaReaderProjectionRequest requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.authorID = authorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.authorID?.isEmpty == true {
            self.authorID = nil
        }
        self.offlineOwnerName = offlineOwnerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.offlineOwnerName?.isEmpty == true {
            self.offlineOwnerName = nil
        }
    }

    public init(chapter: MangaChapter, offlineOwnerName: String? = nil) {
        self.init(threadID: chapter.tid, view: chapter.view, authorID: chapter.authorUID, offlineOwnerName: offlineOwnerName)
    }
}

public protocol MangaReaderProjectionLoading: Sendable {
    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection
}

public struct MangaReaderProjectionSnapshot: Sendable {
    public var projection: MangaReaderProjection
    public var sourcePage: ForumThreadPage

    public init(projection: MangaReaderProjection, sourcePage: ForumThreadPage) {
        self.projection = projection
        self.sourcePage = sourcePage
    }
}

public protocol MangaReaderProjectionSnapshotLoading: MangaReaderProjectionLoading {
    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot
}

protocol MangaReaderProjectionPersisting: Sendable {
    func projection(for identity: MangaReaderProjectionSourceIdentity) async -> MangaReaderProjection?
    func save(_ projection: MangaReaderProjection) async throws
    func clearAll() async throws
}

public struct MangaDirectorySeed: Hashable, Sendable {
    public var currentChapter: MangaChapter
    public var tagIDs: [String]
    public var samePageChapters: [MangaChapter]
    public var cleanBookName: String
    public var firstPostID: String?

    public init(
        currentChapter: MangaChapter,
        tagIDs: [String] = [],
        samePageChapters: [MangaChapter] = [],
        cleanBookName: String,
        firstPostID: String? = nil
    ) {
        self.currentChapter = currentChapter
        self.tagIDs = tagIDs
        self.samePageChapters = samePageChapters
        self.cleanBookName = cleanBookName
        let normalizedFirstPostID = firstPostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firstPostID = normalizedFirstPostID?.isEmpty == false ? normalizedFirstPostID : nil
    }
}

public protocol MangaDirectoryRepository: Sendable {
    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed
    /// `allowedForumID` scopes the tag list to rows belonging to that board
    /// (the launching thread's board fid, pluggable-reader-config decision
    /// #6) — tag pages mix threads from every board, so rows from other
    /// boards are dropped.
    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter]
    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter]
}

/// Captured with directory content before an asynchronous network refresh.
/// Source IDs are provenance, not aliases, and must not follow redirects.
public struct MangaDirectoryRefreshSnapshot: Sendable {
    public let directory: MangaDirectory
    public let contentIdentityIDs: Set<String>

    public init(directory: MangaDirectory, contentIdentityIDs: Set<String>) {
        self.directory = directory
        self.contentIdentityIDs = contentIdentityIDs
    }
}

public protocol MangaDirectoryPersisting: MangaDirectoryRenaming, MangaDirectoryReading, MangaDirectoryChangeObserving {
    func directoryRefreshSnapshot(id: MangaDirectoryID) async throws -> MangaDirectoryRefreshSnapshot?
    func saveRefreshedDirectory(_ directory: MangaDirectory, from snapshot: MangaDirectoryRefreshSnapshot) async throws -> MangaDirectory
    /// Atomically adopts an existing discovery identity or persists a new seed.
    func resolveOrCreateDirectory(_ seed: MangaDirectory) async throws -> MangaDirectory
    func resolveDirectoryID(legacyName: String?, legacyIdentity: String?, chapterTID: String?) async throws -> MangaDirectoryID?
    func registerIdentity(id: MangaDirectoryID, name: String) async throws
    func identityName(id: MangaDirectoryID) async throws -> String?
    func saveDirectory(_ directory: MangaDirectory) async throws
    func deleteDirectory(id: MangaDirectoryID) async throws
}

/// Replaces a directory identity and its persisted references atomically.
/// A failed rename must leave both identities unchanged.
public protocol MangaDirectoryRenaming: Sendable {
    func renameDirectory(id: MangaDirectoryID, cleanBookName: String, searchKeyword: String?) async throws -> MangaDirectory
    func mergeDirectories(sourceID: MangaDirectoryID, targetID: MangaDirectoryID, cleanBookName: String, searchKeyword: String?) async throws -> MangaDirectory
}
