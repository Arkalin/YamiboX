import CoreGraphics
import Foundation

public struct NovelReaderSurfaceIdentity: Hashable, Sendable {
    public var generation: UInt64
    package var ordinal: Int

    package init(generation: UInt64, ordinal: Int) {
        self.generation = generation
        self.ordinal = max(0, ordinal)
    }
}

public enum NovelReaderSurfaceKind: Hashable, Sendable {
    case text
    case externalBlock
}

public struct NovelReaderExternalBlock: Hashable, Sendable {
    public var url: URL
    public var frame: CGRect?
    public var chapterIdentity: NovelChapterIdentity?
    public var imageSegmentIdentity: NovelTextSegmentIdentity?
    public var chapterOrdinal: Int?

    public init(
        url: URL,
        frame: CGRect?,
        chapterIdentity: NovelChapterIdentity? = nil,
        imageSegmentIdentity: NovelTextSegmentIdentity? = nil,
        chapterOrdinal: Int? = nil
    ) {
        self.url = url
        self.frame = frame
        self.chapterIdentity = chapterIdentity
        self.imageSegmentIdentity = imageSegmentIdentity
        self.chapterOrdinal = chapterOrdinal
    }
}

public struct NovelReaderSurface: Hashable, Sendable {
    public var identity: NovelReaderSurfaceIdentity
    public var presentationIndex: Int
    public var kind: NovelReaderSurfaceKind
    public var documentView: Int
    public var chapterTitle: String?
    public var presentationSize: CGSize
    public var presentationSpacingAfter: CGFloat
    public var externalBlocks: [NovelReaderExternalBlock]
    public var chapterCommentTarget: ReaderChapterCommentTarget?
    /// The owning projection's cache-key identity (see
    /// `NovelImageLikeAnchor.resolvedAuthorID`) — uniform across every
    /// surface built from the same `NovelReaderProjection`.
    public var resolvedAuthorID: String?

    public init(
        identity: NovelReaderSurfaceIdentity,
        presentationIndex: Int = 0,
        kind: NovelReaderSurfaceKind,
        documentView: Int,
        chapterTitle: String?,
        presentationSize: CGSize,
        presentationSpacingAfter: CGFloat = 0,
        externalBlocks: [NovelReaderExternalBlock] = [],
        chapterCommentTarget: ReaderChapterCommentTarget? = nil,
        resolvedAuthorID: String? = nil
    ) {
        self.identity = identity
        self.presentationIndex = max(0, presentationIndex)
        self.kind = kind
        self.documentView = max(1, documentView)
        self.chapterTitle = chapterTitle
        self.presentationSize = presentationSize
        self.presentationSpacingAfter = max(0, presentationSpacingAfter)
        self.externalBlocks = externalBlocks
        self.chapterCommentTarget = chapterCommentTarget
        self.resolvedAuthorID = resolvedAuthorID
    }
}

public struct NovelReaderPresentationSpread: Hashable, Sendable {
    public var index: Int
    public var leftSurfaceIndex: Int
    public var leftSurfaceIdentity: NovelReaderSurfaceIdentity
    public var rightSurfaceIndex: Int?
    public var rightSurfaceIdentity: NovelReaderSurfaceIdentity?
    public var chapterTitle: String?

    public init(
        index: Int,
        leftSurfaceIndex: Int = 0,
        leftSurfaceIdentity: NovelReaderSurfaceIdentity,
        rightSurfaceIndex: Int? = nil,
        rightSurfaceIdentity: NovelReaderSurfaceIdentity?,
        chapterTitle: String?
    ) {
        self.index = max(0, index)
        self.leftSurfaceIndex = max(0, leftSurfaceIndex)
        self.leftSurfaceIdentity = leftSurfaceIdentity
        self.rightSurfaceIndex = rightSurfaceIndex.map { max(0, $0) }
        self.rightSurfaceIdentity = rightSurfaceIdentity
        self.chapterTitle = chapterTitle
    }
}
