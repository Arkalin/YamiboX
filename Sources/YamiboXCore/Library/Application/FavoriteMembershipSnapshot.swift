import Foundation

/// The surface's subject, independent of the chapter used to create a favorite.
public enum FavoriteMembershipScope: Equatable, Sendable {
    case thread(String)
    case manga(threadID: String, title: String, forumID: String?, directoryTitle: String? = nil)

    public var threadID: String {
        switch self {
        case let .thread(id), let .manga(id, _, _, _): id
        }
    }

    public init(entry: BrowsingHistoryEntry, boardReader: BoardReaderSettings) {
        let tid = entry.target.threadID ?? entry.chapterThreadID ?? entry.lastVisitedThreadID ?? ""
        if entry.category(boardReader: boardReader) == .manga,
           entry.target.kind == .mangaTitle || boardReader.isSmartComicModeEnabled(forumID: entry.forumID) {
            self = .manga(threadID: tid, title: entry.title, forumID: entry.forumID, directoryTitle: entry.target.mangaCleanBookName)
        } else {
            self = .thread(tid)
        }
    }
}

public struct FavoriteMembership: Equatable, Sendable {
    public let items: [FavoriteItem]
    public let smartMangaTitle: String?
    public var favoriteIDs: Set<String> { Set(items.map(\.id)) }
    public var isFavorited: Bool { !items.isEmpty }
    public var isSmartManga: Bool { smartMangaTitle != nil }
}

/// One local batch read supplies all rows, filtering, and commands. Membership
/// deliberately shares the favorite library's archive semantics, not a second
/// chapter/title grouping algorithm.
public struct FavoriteMembershipSnapshot: Sendable {
    public let document: FavoriteLibraryDocument
    public let boardReader: BoardReaderSettings
    private let directories: [String: MangaDirectory]
    private let itemsByThread: [String: [FavoriteItem]]
    private let archivedItemsByTitle: [String: [FavoriteItem]]

    public init(document: FavoriteLibraryDocument, directories: [String: MangaDirectory], boardReader: BoardReaderSettings) {
        self.document = document
        self.directories = directories
        self.boardReader = boardReader
        itemsByThread = Dictionary(grouping: document.items, by: { $0.target.threadID ?? "" })
        archivedItemsByTitle = LocalFavoriteLibraryProjection.mangaThreadItemsByEffectiveTitle(
            in: document.items, mangaDirectoriesByTID: directories, boardReaderSettings: boardReader
        )
    }

    public static func load(
        libraryStore: FavoriteLibraryStore,
        directoryStore: (any MangaDirectoryPersisting)?,
        boardReader: BoardReaderSettings,
        additionalThreadIDs: [String] = []
    ) async throws -> Self {
        let document = try await libraryStore.load()
        let tids = Array(Set(document.items.compactMap { $0.target.threadID } + additionalThreadIDs)).filter { !$0.isEmpty }
        let directories = try await directoryStore?.directories(containingTIDs: tids) ?? [:]
        try Task.checkCancellation()
        return Self(document: document, directories: directories, boardReader: boardReader)
    }

    public func membership(for scope: FavoriteMembershipScope) -> FavoriteMembership {
        let direct = itemsByThread[scope.threadID] ?? []
        guard case let .manga(tid, title, forumID, confirmedTitle) = scope,
              forumID == nil || boardReader.isSmartComicModeEnabled(forumID: forumID) else {
            return FavoriteMembership(items: direct, smartMangaTitle: nil)
        }
        let directory = directories[tid]
        let effectiveTitle: String
        if let directory {
            effectiveTitle = directory.cleanBookName
        } else if let confirmedTitle {
            // A canonical history title has already been resolved/corrected;
            // running a chapter-title cleaner again can change its identity.
            effectiveTitle = confirmedTitle
        } else if let item = direct.first(where: { $0.target.kind == .mangaThread }) {
            effectiveTitle = FavoriteCardProjection.resolvedTitle(item: item, mangaDirectory: directory, isModeOnMangaThread: true)
        } else {
            effectiveTitle = FavoriteCardProjection.resolvedSmartMangaTitle(title, directory: directory)
        }
        let members = archivedItemsByTitle[effectiveTitle] ?? []
        // Older, explicitly per-thread favorites must retain their direct
        // match even when their board's reader configuration has changed.
        if members.isEmpty, !direct.isEmpty {
            return FavoriteMembership(items: direct, smartMangaTitle: nil)
        }
        return FavoriteMembership(items: members, smartMangaTitle: effectiveTitle)
    }

    public func membership(for entry: BrowsingHistoryEntry) -> FavoriteMembership {
        membership(for: FavoriteMembershipScope(entry: entry, boardReader: boardReader))
    }
}
