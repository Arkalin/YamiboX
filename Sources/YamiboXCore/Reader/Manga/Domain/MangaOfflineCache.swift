import Foundation

public struct MangaOfflineCacheMembershipID: Codable, Hashable, Sendable {
    public var ownerName: String
    public var tid: String

    public init(ownerName: String, tid: String) {
        self.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct MangaOfflineCacheMembership: Codable, Hashable, Identifiable, Sendable {
    public var ownerName: String
    public var tid: String
    public var chapterTitle: String
    public var imageURLs: [URL]
    public var sourcePage: ForumThreadPage
    public var createdAt: Date

    public var id: MangaOfflineCacheMembershipID {
        MangaOfflineCacheMembershipID(ownerName: ownerName, tid: tid)
    }

    public init(
        ownerName: String,
        tid: String,
        chapterTitle: String,
        imageURLs: [URL],
        sourcePage: ForumThreadPage,
        createdAt: Date = .now
    ) {
        self.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chapterTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageURLs = imageURLs
        self.sourcePage = sourcePage
        self.createdAt = createdAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ownerName)
        hasher.combine(tid)
        hasher.combine(chapterTitle)
        hasher.combine(imageURLs)
        hasher.combine(createdAt)
    }
}

public struct MangaOfflineCacheOwnerUsage: Codable, Equatable, Sendable {
    public var ownerName: String
    public var byteCount: Int

    public init(ownerName: String, byteCount: Int) {
        self.ownerName = ownerName
        self.byteCount = max(0, byteCount)
    }
}

public enum MangaOfflineCacheState: String, Codable, Hashable, Sendable {
    case cached
    case uncached
    case caching
}

public struct MangaOfflineCacheWorkRequest: Hashable, Sendable {
    public var ownerName: String
    public var tid: String
    public var chapterTitle: String
    public var targetImageURLs: [URL]

    public init(
        ownerName: String,
        tid: String,
        chapterTitle: String,
        targetImageURLs: [URL] = []
    ) {
        self.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chapterTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetImageURLs = Self.uniqueURLs(targetImageURLs)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted {
            output.append(url)
        }
        return output
    }
}

public enum MangaOfflineCacheEnqueueResult: Hashable, Sendable {
    case alreadyCached(MangaOfflineCacheMembership)
    case alreadyQueued(OfflineCacheQueueWorkProjection)
    case enqueued(OfflineCacheQueueWorkProjection)

    public var enqueuedWork: OfflineCacheQueueWorkProjection? {
        if case let .enqueued(work) = self {
            return work
        }
        return nil
    }
}
