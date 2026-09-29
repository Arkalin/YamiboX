import Foundation

public struct MangaDownloadMembershipID: Codable, Hashable, Sendable {
    public var ownerName: String
    public var tid: String

    public init(ownerName: String, tid: String) {
        self.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct MangaDownloadMembership: Codable, Hashable, Identifiable, Sendable {
    public var ownerName: String
    public var tid: String
    public var chapterTitle: String
    public var imageURLs: [URL]
    public var sourcePage: ForumThreadPage
    public var createdAt: Date

    public var id: MangaDownloadMembershipID {
        MangaDownloadMembershipID(ownerName: ownerName, tid: tid)
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

public struct MangaDownloadOwnerUsage: Codable, Equatable, Sendable {
    public var ownerName: String
    public var byteCount: Int

    public init(ownerName: String, byteCount: Int) {
        self.ownerName = ownerName
        self.byteCount = max(0, byteCount)
    }
}

public enum MangaDownloadState: String, Codable, Hashable, Sendable {
    case downloaded
    case notDownloaded
    case downloading
}

public struct MangaDownloadWorkRequest: Hashable, Sendable {
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
        self.targetImageURLs = targetImageURLs.removingDuplicateURLs()
    }
}

public enum MangaDownloadEnqueueResult: Hashable, Sendable {
    case alreadyDownloaded(MangaDownloadMembership)
    case alreadyQueued(DownloadQueueWorkProjection)
    case enqueued(DownloadQueueWorkProjection)

    public var enqueuedWork: DownloadQueueWorkProjection? {
        if case let .enqueued(work) = self {
            return work
        }
        return nil
    }
}
