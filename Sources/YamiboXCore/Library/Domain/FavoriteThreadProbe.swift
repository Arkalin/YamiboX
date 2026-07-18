import Foundation

// Importing a thread as a favorite: what probing the thread page yields
// (`FavoriteThreadProbeResult`), how an import can fail, the open route a
// favorite's target resolves to, and the date resolver that feeds
// `contentUpdatedAt` — one file because they only appear together on the
// probe/import path.

/// Public shell kept for API stability; the actual edit-note grammar and date
/// formats live in `DiscuzEditedDateParser`, shared with the thread-page post
/// parser so the two can no longer drift apart.
public enum FavoriteContentUpdateDateResolver {
    public static func date(lastEditedText: String?, postedAtText: String?) -> Date? {
        DiscuzEditedDateParser.date(lastEditedText: lastEditedText, postedAtText: postedAtText)
    }

    public static func date(from text: String?) -> Date? {
        DiscuzEditedDateParser.date(from: text)
    }
}

public struct FavoriteThreadProbeResult: Hashable, Sendable {
    public var target: FavoriteItemTarget
    public var title: String
    public var sourceGroup: FavoriteSourceGroup
    public var forumID: String?
    public var forumName: String?
    public var coverURL: URL?
    public var contentUpdatedAt: Date?
    public var authorID: String?
    /// Set when the thread-page fetch backing `sourceGroup`/`coverURL`/
    /// `contentUpdatedAt` failed even after retries, so the caller can still
    /// import the item while surfacing that its metadata is degraded rather
    /// than silently treating it as a clean success.
    public var sourceMetadataFetchFailed: Bool

    public init(
        target: FavoriteItemTarget,
        title: String,
        sourceGroup: FavoriteSourceGroup = .unknown,
        forumID: String? = nil,
        forumName: String? = nil,
        coverURL: URL? = nil,
        contentUpdatedAt: Date? = nil,
        authorID: String? = nil,
        sourceMetadataFetchFailed: Bool = false
    ) {
        self.target = target
        self.title = title
        let forumMetadata = FavoriteSourceGroup.normalizedForumMetadata(
            sourceGroup: sourceGroup,
            forumID: forumID,
            forumName: forumName
        )
        self.sourceGroup = forumMetadata.sourceGroup
        self.forumID = forumMetadata.forumID
        self.forumName = forumMetadata.forumName
        self.coverURL = coverURL
        self.contentUpdatedAt = contentUpdatedAt
        self.authorID = authorID
        self.sourceMetadataFetchFailed = sourceMetadataFetchFailed
    }
}

enum FavoriteThreadImportFailure: Error, Equatable, Sendable {
    case probeFailed(String)
    case unsupportedTarget
}

public enum FavoriteItemOpenRoute: Equatable, Sendable {
    case nativeThread(threadID: String)
    case novelDetail(threadID: String)
    /// Renamed from `.mangaTitle(cleanBookName:)`: favorites no longer carry
    /// a merged-directory identity, so this now names the single chapter
    /// thread the favorite points at (smart-comic-mode design decision #9's
    /// second correction).
    case mangaThread(threadID: String)
    case unsupported
}
