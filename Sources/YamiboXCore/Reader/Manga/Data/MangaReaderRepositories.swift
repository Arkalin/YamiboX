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

public protocol MangaDirectoryPersisting: Sendable {
    func directory(named name: String) async throws -> MangaDirectory?
    func directory(containingTID tid: String) async throws -> MangaDirectory?
    /// Bulk tid → owning-directory lookup (smart-comic-mode Phase E): tids
    /// that resolve to a directory are present in the result keyed by the
    /// tid itself; tids with no resolved directory are simply absent — never
    /// an error. Conformers should implement this as a single batched query
    /// rather than looping `directory(containingTID:)` once per tid (the
    /// design doc's "现算分组的性能要求" hard constraint #1) — see
    /// `MangaDirectoryStore`'s override for the real single-query
    /// implementation. The default below is a naive per-tid fallback that
    /// exists only so lightweight test fakes don't all need updating; it
    /// must never be the implementation favorites grouping actually runs
    /// against in the shipping app.
    func directories(containingTIDs tids: [String]) async throws -> [String: MangaDirectory]
    func saveDirectory(_ directory: MangaDirectory) async throws
    func deleteDirectory(named name: String) async throws
    /// Instance identity carried by every element of `changes()`, kept so
    /// listeners can hold on to their existing "is this change from the
    /// exact instance I observe?" guard — mirrors `ContentCoverStore`/
    /// `FavoriteLibraryStore`'s own `changeID` pattern. Defaulted below for
    /// every conformer except the real `MangaDirectoryStore`, which never
    /// broadcasts through this protocol and so never needs a listener to
    /// match against it.
    nonisolated var changeID: String { get }
    /// Typed change feed replacing the retired `didChangeNotification`
    /// string bus; each element is the `changeID` of the conforming instance
    /// that made the change. Defaulted below so lightweight test fakes —
    /// which never broadcast — don't all need updating.
    nonisolated func changes() -> AsyncStream<String>
}

/// Shared sink backing the default `changes()`: nothing ever posts through
/// it, so a listener on a non-broadcasting conformer parks until cancelled —
/// the exact observable behavior of the old default, which subscribed to a
/// notification no fake ever sent. One shared instance (not one per call)
/// so the registered continuation stays alive for as long as the consumer
/// keeps iterating.
private let neverBroadcastingChangeSink = StoreChangeBroadcaster()

public extension MangaDirectoryPersisting {
    func directories(containingTIDs tids: [String]) async throws -> [String: MangaDirectory] {
        var result: [String: MangaDirectory] = [:]
        for tid in tids {
            if let directory = try await directory(containingTID: tid) {
                result[tid] = directory
            }
        }
        return result
    }

    nonisolated var changeID: String { "" }

    nonisolated func changes() -> AsyncStream<String> {
        neverBroadcastingChangeSink.changes()
    }
}

protocol MangaDirectoryRenaming: Sendable {
    func renameDirectory(
        from oldName: String,
        to newDirectory: MangaDirectory
    ) async throws
}

