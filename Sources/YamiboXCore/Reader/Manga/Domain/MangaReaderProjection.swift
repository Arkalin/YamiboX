import Foundation

public struct MangaReaderProjectionSourceIdentity: Codable, Hashable, Sendable {
    public var tid: String
    public var authorID: String?
    public var view: Int

    public init(
        tid: String,
        authorID: String?,
        view: Int
    ) {
        self.tid = tid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorID = authorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.authorID?.isEmpty == true {
            self.authorID = nil
        }
        self.view = max(1, view)
    }
}

public struct MangaReaderProjection: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let parserVersion = 1

    public var tid: String
    public var ownerPostID: String
    public var ownerAuthorID: String?
    public var ownerAuthorName: String?
    public var chapterTitle: String
    public var imageURLs: [URL]
    public var sourceIdentity: MangaReaderProjectionSourceIdentity
    public var sourceFingerprint: String
    public var schemaVersion: Int
    public var parserVersion: Int

    public init(
        tid: String,
        ownerPostID: String? = nil,
        ownerAuthorID: String? = nil,
        ownerAuthorName: String? = nil,
        chapterTitle: String,
        imageURLs: [URL],
        sourceIdentity: MangaReaderProjectionSourceIdentity? = nil,
        sourceFingerprint: String = "",
        schemaVersion: Int = Self.schemaVersion,
        parserVersion: Int = Self.parserVersion
    ) {
        self.tid = tid
        let normalizedOwnerPostID = ownerPostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedOwnerPostID, !normalizedOwnerPostID.isEmpty {
            self.ownerPostID = normalizedOwnerPostID
        } else {
            self.ownerPostID = tid
        }
        self.ownerAuthorID = ownerAuthorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.ownerAuthorID?.isEmpty == true {
            self.ownerAuthorID = nil
        }
        self.ownerAuthorName = ownerAuthorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.ownerAuthorName?.isEmpty == true {
            self.ownerAuthorName = nil
        }
        self.chapterTitle = chapterTitle
        self.imageURLs = imageURLs
        self.sourceIdentity = sourceIdentity ?? MangaReaderProjectionSourceIdentity(
            tid: tid,
            authorID: self.ownerAuthorID,
            view: 1
        )
        self.sourceFingerprint = sourceFingerprint
        self.schemaVersion = schemaVersion
        self.parserVersion = parserVersion
    }
}
