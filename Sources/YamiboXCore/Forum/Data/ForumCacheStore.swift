import Foundation
@preconcurrency import GRDB

public actor ForumCacheStore {
    public static let homeTTL: TimeInterval = 12 * 60 * 60
    public static let boardTTL: TimeInterval = 2 * 60 * 60
    public static let threadPageTTL: TimeInterval = 24 * 60 * 60
    private static let threadPageMaxEntries = 50
    private static let boardMaxEntries = 50
    public static let homeNamespace = "forum-home"
    public static let boardNamespace = "forum-boards"
    public static let threadPageNamespace = "forum-thread-pages"
    private static let homeKey = "home"

    private let cacheStore: DiskCacheStore
    private let now: @Sendable () -> Date
    private nonisolated(unsafe) let fileManager: FileManager

    init(
        databasePool: DatabasePool? = nil,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        baseDirectory: URL? = nil,
        diskCacheStore: DiskCacheStore? = nil,
        threadPageDiskCache: DiskCacheStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let injectedCacheStore = diskCacheStore ?? threadPageDiskCache {
            self.cacheStore = injectedCacheStore
        } else {
            // An injected directory hosts both the database and the cache
            // files (tests); the no-argument fallback mirrors the app context:
            // yamibox.sqlite in Application Support, yamibox-cache in Caches.
            let injectedRootDirectory = rootDirectory ?? baseDirectory
            let resolvedDatabase = databasePool ?? Self.openDatabase(
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultRootDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
            self.cacheStore = DiskCacheStore(
                writer: resolvedDatabase,
                rootDirectory: injectedRootDirectory ?? YamiboDatabase.defaultCacheRootDirectory(fileManager: fileManager),
                now: now
            )
        }
        self.now = now
        self.fileManager = fileManager
    }

    public func loadHome(allowExpired: Bool = false) async -> ForumHomePage? {
        let ttl = allowExpired ? nil : Self.homeTTL
        guard let entry: ForumCacheEntry<ForumHomePage> = await loggedGet(
            namespace: Self.homeNamespace,
            key: Self.homeKey,
            ttl: ttl
        ) else {
            return nil
        }
        return entry.value
    }

    public func saveHome(_ page: ForumHomePage) async throws {
        try await cacheStore.set(
            ForumCacheEntry(value: page, fetchedAt: page.fetchedAt),
            namespace: Self.homeNamespace,
            key: Self.homeKey
        )
    }

    public func loadBoard(
        fid: String,
        page: Int = 1,
        filterID: String? = nil,
        orderFilter: String? = nil,
        orderBy: String? = nil,
        allowExpired: Bool = false
    ) async -> ForumBoardPage? {
        let ttl = allowExpired ? nil : Self.boardTTL
        guard let entry: ForumCacheEntry<ForumBoardPage> = await loggedGet(
            namespace: Self.boardNamespace,
            key: boardCacheKey(fid: fid, page: page, filterID: filterID, orderFilter: orderFilter, orderBy: orderBy),
            ttl: ttl
        ) else {
            return nil
        }
        return entry.value
    }

    public func saveBoard(
        _ page: ForumBoardPage,
        fid: String,
        pageNumber: Int = 1,
        filterID: String? = nil,
        orderFilter: String? = nil,
        orderBy: String? = nil
    ) async throws {
        try await cacheStore.set(
            ForumCacheEntry(value: page, fetchedAt: page.fetchedAt),
            namespace: Self.boardNamespace,
            key: boardCacheKey(fid: fid, page: pageNumber, filterID: filterID, orderFilter: orderFilter, orderBy: orderBy)
        )
        try await cacheStore.trimNamespace(Self.boardNamespace, maximumEntryCount: Self.boardMaxEntries)
    }

    public func loadThreadPage(
        thread: ThreadIdentity,
        page: Int = 1,
        authorID: String? = nil,
        allowExpired: Bool = false
    ) async -> ForumThreadPage? {
        let ttl = allowExpired ? nil : Self.threadPageTTL
        guard let entry: ForumCacheEntry<ForumThreadPage> = await loggedGet(
            namespace: Self.threadPageNamespace,
            key: threadPageCacheKey(thread: thread, page: page, authorID: authorID),
            ttl: ttl
        ) else {
            return nil
        }
        return entry.value
    }

    public func cachedThreadPageViews(
        thread: ThreadIdentity,
        authorID: String? = nil,
        allowExpired: Bool = false
    ) async -> Set<Int> {
        let prefix = threadPageCacheKeyPrefix(thread: thread)
        let normalizedAuthorID = authorID?.nilIfBlank
        let entries: [DiskCacheStore.CacheEntry]
        do {
            entries = try await cacheStore.entries(namespace: Self.threadPageNamespace)
        } catch {
            YamiboLog.offlineCache.warning("ForumCacheStore: failed to list cache entries namespace=\(Self.threadPageNamespace, privacy: .public): \(error)")
            entries = []
        }
        return Set(entries.compactMap { entry -> Int? in
            guard entry.key.hasPrefix(prefix),
                  threadPageCacheAuthorID(from: entry.key) == normalizedAuthorID,
                  allowExpired || !isExpired(entry.createdAt, ttl: Self.threadPageTTL) else {
                return nil
            }
            return threadPageCachePage(from: entry.key)
        })
    }

    public func saveThreadPage(
        _ page: ForumThreadPage,
        thread: ThreadIdentity,
        pageNumber: Int = 1,
        authorID: String? = nil
    ) async throws {
        var page = page
        if page.pageNavigation?.currentPage == nil {
            page.pageNavigation = ForumPageNavigation(
                currentPage: max(1, pageNumber),
                totalPages: page.pageNavigation?.totalPages
            )
        }
        try await cacheStore.set(
            ForumCacheEntry(value: page, fetchedAt: now()),
            namespace: Self.threadPageNamespace,
            key: threadPageCacheKey(thread: thread, page: pageNumber, authorID: authorID)
        )
        try await cacheStore.trimNamespace(Self.threadPageNamespace, maximumEntryCount: Self.threadPageMaxEntries)
    }

    public func clearThreadPages(thread: ThreadIdentity) async throws {
        try await cacheStore.deleteKeys(
            namespace: Self.threadPageNamespace,
            matchingPrefix: threadPageCacheKeyPrefix(thread: thread)
        )
    }

    public func deleteThreadPages(
        _ pages: Set<Int>,
        thread: ThreadIdentity,
        authorID: String?
    ) async throws {
        let normalizedAuthorID = authorID?.nilIfBlank
        let normalizedPages = Set(pages.map { max(1, $0) })
        guard !normalizedPages.isEmpty else { return }
        for page in normalizedPages {
            try await cacheStore.remove(
                namespace: Self.threadPageNamespace,
                key: threadPageCacheKey(thread: thread, page: page, authorID: normalizedAuthorID)
            )
        }
    }

    public func clearAll() async throws {
        try await cacheStore.clearNamespace(Self.homeNamespace)
        try await cacheStore.clearNamespace(Self.boardNamespace)
        try await cacheStore.clearNamespace(Self.threadPageNamespace)
    }

    public func totalDiskUsageBytes() async -> Int {
        var total = 0
        for namespace in [Self.homeNamespace, Self.boardNamespace, Self.threadPageNamespace] {
            let entries: [DiskCacheStore.CacheEntry]
            do {
                entries = try await cacheStore.entries(namespace: namespace)
            } catch {
                YamiboLog.offlineCache.warning("ForumCacheStore: failed to enumerate entries namespace=\(namespace, privacy: .public) for disk usage: \(error)")
                continue
            }
            for entry in entries {
                guard let fileURL = try? await cacheStore.fileURL(namespace: entry.namespace, key: entry.key),
                      let byteCount = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
                    continue
                }
                total += byteCount.intValue
            }
        }
        return total
    }

    private func isExpired(_ fetchedAt: Date, ttl: TimeInterval) -> Bool {
        now().timeIntervalSince(fetchedAt) > ttl
    }

    /// Wraps `DiskCacheStore.get`, logging genuine read/decode errors (as opposed to a plain
    /// cache miss, which `get` already represents as `nil` without throwing).
    private func loggedGet<Value: Decodable & Sendable>(
        namespace: String,
        key: String,
        ttl: TimeInterval?
    ) async -> Value? {
        do {
            return try await cacheStore.get(namespace: namespace, key: key, ttl: ttl)
        } catch {
            YamiboLog.offlineCache.warning("ForumCacheStore: cache read failed namespace=\(namespace, privacy: .public) key=\(key, privacy: .public): \(error)")
            return nil
        }
    }

    private func boardCacheKey(fid: String, page: Int, filterID: String?, orderFilter: String?, orderBy: String?) -> String {
        let key = [
            fid,
            String(max(1, page)),
            filterID?.nilIfBlank ?? "all",
            orderFilter?.nilIfBlank ?? "default",
            orderBy?.nilIfBlank ?? "default"
        ].joined(separator: "_")
        return "board_\(stableIdentifier(for: key))"
    }

    private func threadPageCacheKey(thread: ThreadIdentity, page: Int, authorID: String?) -> String {
        "\(threadPageCacheKeyPrefix(thread: thread))page_\(max(1, page))_author_\(authorID?.nilIfBlank ?? "all")"
    }

    private func threadPageCacheKeyPrefix(thread: ThreadIdentity) -> String {
        "tid_\(thread.tid)_"
    }

    private func threadPageCachePage(from key: String) -> Int? {
        key.components(separatedBy: "_").enumerated().first { $0.element == "page" }
            .flatMap { index, parts -> Int? in
                let components = key.components(separatedBy: "_")
                guard components.indices.contains(index + 1) else { return nil }
                return Int(components[index + 1])
            }
    }

    private func threadPageCacheAuthorID(from key: String) -> String? {
        let components = key.components(separatedBy: "_")
        guard let index = components.firstIndex(of: "author"),
              components.indices.contains(index + 1) else {
            return nil
        }
        let value = components[index + 1]
        return value == "all" ? nil : value
    }

    private func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func openDatabase(rootDirectory: URL, fileManager: FileManager) -> DatabasePool {
        do {
            return try YamiboDatabase.openPool(rootDirectory: rootDirectory, fileManager: fileManager)
        } catch {
            fatalError("Failed to open ForumCacheStore database: \(error)")
        }
    }
}

private struct ForumCacheEntry<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value
    var fetchedAt: Date
}
