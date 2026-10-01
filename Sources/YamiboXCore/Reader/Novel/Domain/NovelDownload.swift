import Foundation

public struct NovelDownloadEntry: Codable, Hashable, Identifiable, Sendable {
    public static let sourcePageSchemaVersion = 1

    public var ownerTitle: String
    public var title: String
    public var document: NovelReaderProjection
    public var imageURLs: [URL]
    public var updatedAt: Date

    public var id: DownloadEntryID {
        DownloadEntryID(
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

    static func entryKeyComponents(from key: String) -> NovelDownloadEntryKeyComponents? {
        guard let components = ReaderCacheKeyCodec.components(from: key) else { return nil }
        return NovelDownloadEntryKeyComponents(
            threadID: components.threadID,
            authorID: components.authorID,
            view: components.view
        )
    }

    public static func defaultTitle(document: NovelReaderProjection) -> String {
        L10n.string("reader.page_number_spaced", document.view)
    }
}

struct NovelDownloadEntryKeyComponents {
    var threadID: String
    var authorID: String?
    var view: Int
}

public struct NovelDownloadWorkRequest: Hashable, Sendable {
    public var ownerTitle: String
    public var title: String
    public var threadID: String
    public var view: Int
    public var authorID: String?
    public var targetImageURLs: [URL]
    public var retainsInlineImages: Bool

    public var entryKey: String {
        NovelDownloadEntry.entryKey(
            threadID: threadID,
            view: view,
            authorID: authorID
        )
    }

    public var groupKey: String {
        NovelDownloadEntry.groupKey(
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
        precondition(!normalizedThreadID.isEmpty, "NovelDownloadWorkRequest requires a Yamibo thread tid")
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

public enum NovelDownloadEnqueueResult: Hashable, Sendable {
    case alreadyDownloaded(NovelDownloadEntry)
    case alreadyQueued(DownloadQueueWorkProjection)
    case enqueued(DownloadQueueWorkProjection)

    public var enqueuedWork: DownloadQueueWorkProjection? {
        if case let .enqueued(work) = self {
            return work
        }
        return nil
    }
}

public enum NovelDownloadViewStatus: String, Codable, Hashable, Sendable {
    case notDownloaded
    case downloaded
    case downloading
}

public struct NovelDownloadViewState: Codable, Hashable, Sendable {
    public var view: Int
    public var status: NovelDownloadViewStatus
    public var updatedAt: Date?

    public init(view: Int, status: NovelDownloadViewStatus, updatedAt: Date? = nil) {
        self.view = max(1, view)
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct NovelDownloadViewsSnapshot: Codable, Hashable, Sendable {
    public var downloadedViews: Set<Int>
    public var downloadingViews: Set<Int>
    public var updateTimesByView: [Int: Date]

    public init(
        downloadedViews: Set<Int> = [],
        downloadingViews: Set<Int> = [],
        updateTimesByView: [Int: Date] = [:]
    ) {
        self.downloadedViews = downloadedViews
        self.downloadingViews = downloadingViews
        self.updateTimesByView = updateTimesByView
    }

    public func state(for view: Int) -> NovelDownloadViewState {
        let normalizedView = max(1, view)
        if downloadingViews.contains(normalizedView) {
            return NovelDownloadViewState(
                view: normalizedView,
                status: .downloading,
                updatedAt: updateTimesByView[normalizedView]
            )
        }
        if downloadedViews.contains(normalizedView) {
            return NovelDownloadViewState(
                view: normalizedView,
                status: .downloaded,
                updatedAt: updateTimesByView[normalizedView]
            )
        }
        return NovelDownloadViewState(view: normalizedView, status: .notDownloaded)
    }
}

public struct NovelOfflineSourcePageMetadata: Sendable {
    public var ownerTitle: String
    public var updatedAt: Date?
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
