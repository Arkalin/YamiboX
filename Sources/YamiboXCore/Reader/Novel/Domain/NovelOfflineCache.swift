import Foundation

public struct NovelOfflineCacheEntry: Codable, Hashable, Identifiable, Sendable {
    public static let sourcePageSchemaVersion = 1

    public var ownerTitle: String
    public var title: String
    public var document: NovelReaderProjection
    public var imageURLs: [URL]
    public var updatedAt: Date

    public var id: OfflineCacheEntryID {
        OfflineCacheEntryID(
            readerKind: .novel,
            ownerKey: Self.groupKey(document: document),
            entryKey: Self.entryKey(document: document)
        )
    }

    public init(
        ownerTitle: String,
        title: String? = nil,
        document: NovelReaderProjection,
        imageURLs: [URL] = [],
        updatedAt: Date = .now
    ) {
        self.ownerTitle = ownerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if self.title.isEmpty {
            self.title = Self.defaultTitle(document: document)
        }
        self.document = document
        self.imageURLs = imageURLs.removingDuplicateURLs()
        self.updatedAt = updatedAt
    }

    public static func entryKey(document: NovelReaderProjection) -> String {
        entryKey(
            threadID: document.threadID,
            view: document.view,
            authorID: document.resolvedAuthorID
        )
    }

    public static func groupKey(document: NovelReaderProjection) -> String {
        groupKey(
            threadID: document.threadID,
            authorID: document.resolvedAuthorID
        )
    }

    public static func groupKey(
        threadID: String,
        authorID: String?
    ) -> String {
        let identity = NovelReaderCacheIdentity(
            threadID: threadID,
            view: 1,
            authorID: authorID
        )
        return ReaderCacheKeyCodec.groupKey(
            threadID: identity.threadID,
            authorID: identity.authorID
        )
    }

    public static func entryKey(
        threadID: String,
        view: Int,
        authorID: String?
    ) -> String {
        let identity = NovelReaderCacheIdentity(
            threadID: threadID,
            view: view,
            authorID: authorID
        )
        return ReaderCacheKeyCodec.entryKey(
            threadID: identity.threadID,
            view: identity.view,
            authorID: identity.authorID
        )
    }

    static func entryKeyComponents(from key: String) -> NovelOfflineCacheEntryKeyComponents? {
        guard let components = ReaderCacheKeyCodec.components(from: key) else { return nil }
        return NovelOfflineCacheEntryKeyComponents(
            threadID: components.threadID,
            authorID: components.authorID,
            view: components.view
        )
    }

    public static func defaultTitle(document: NovelReaderProjection) -> String {
        L10n.string("reader.page_number_spaced", document.view)
    }
}

struct NovelOfflineCacheEntryKeyComponents {
    var threadID: String
    var authorID: String?
    var view: Int
}

public struct NovelOfflineCacheWorkRequest: Hashable, Sendable {
    public var ownerTitle: String
    public var title: String
    public var threadID: String
    public var view: Int
    public var authorID: String?
    public var targetImageURLs: [URL]
    public var retainsInlineImages: Bool

    public var entryKey: String {
        NovelOfflineCacheEntry.entryKey(
            threadID: threadID,
            view: view,
            authorID: authorID
        )
    }

    public var groupKey: String {
        NovelOfflineCacheEntry.groupKey(
            threadID: threadID,
            authorID: authorID
        )
    }

    public init(
        ownerTitle: String,
        title: String,
        threadID: String,
        view: Int,
        authorID: String? = nil,
        targetImageURLs: [URL] = [],
        retainsInlineImages: Bool = false
    ) {
        self.ownerTitle = ownerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelOfflineCacheWorkRequest requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.authorID = authorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.authorID?.isEmpty == true {
            self.authorID = nil
        }
        self.targetImageURLs = targetImageURLs.removingDuplicateURLs()
        self.retainsInlineImages = retainsInlineImages
    }
}

public enum NovelOfflineCacheEnqueueResult: Hashable, Sendable {
    case alreadyCached(NovelOfflineCacheEntry)
    case alreadyQueued(OfflineCacheQueueWorkProjection)
    case enqueued(OfflineCacheQueueWorkProjection)

    public var enqueuedWork: OfflineCacheQueueWorkProjection? {
        if case let .enqueued(work) = self {
            return work
        }
        return nil
    }
}

public enum NovelOfflineCacheViewStatus: String, Codable, Hashable, Sendable {
    case uncached
    case cached
    case caching
}

public struct NovelOfflineCacheViewState: Codable, Hashable, Sendable {
    public var view: Int
    public var status: NovelOfflineCacheViewStatus
    public var updatedAt: Date?

    public init(view: Int, status: NovelOfflineCacheViewStatus, updatedAt: Date? = nil) {
        self.view = max(1, view)
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct NovelOfflineCacheViewsSnapshot: Codable, Hashable, Sendable {
    public var cachedViews: Set<Int>
    public var cachingViews: Set<Int>
    public var updateTimesByView: [Int: Date]

    public init(
        cachedViews: Set<Int> = [],
        cachingViews: Set<Int> = [],
        updateTimesByView: [Int: Date] = [:]
    ) {
        self.cachedViews = cachedViews
        self.cachingViews = cachingViews
        self.updateTimesByView = updateTimesByView
    }

    public func state(for view: Int) -> NovelOfflineCacheViewState {
        let normalizedView = max(1, view)
        if cachingViews.contains(normalizedView) {
            return NovelOfflineCacheViewState(
                view: normalizedView,
                status: .caching,
                updatedAt: updateTimesByView[normalizedView]
            )
        }
        if cachedViews.contains(normalizedView) {
            return NovelOfflineCacheViewState(
                view: normalizedView,
                status: .cached,
                updatedAt: updateTimesByView[normalizedView]
            )
        }
        return NovelOfflineCacheViewState(view: normalizedView, status: .uncached)
    }
}

public struct NovelOfflineSourcePageSnapshot: Sendable {
    public var ownerTitle: String
    public var sourcePage: ForumThreadPage
    public var updatedAt: Date?

    public init(
        ownerTitle: String,
        sourcePage: ForumThreadPage,
        updatedAt: Date?
    ) {
        self.ownerTitle = ownerTitle
        self.sourcePage = sourcePage
        self.updatedAt = updatedAt
    }
}
