import CoreGraphics
import Foundation

package struct NovelTextViewportIdentity: Hashable, Sendable {
    public var threadID: String
    public var documentView: Int
    public var maxView: Int
    public var fetchedAt: Date
    public var appearance: NovelReaderAppearanceSettings
    public var layout: NovelReaderLayout

    public init(
        threadID: String,
        documentView: Int,
        maxView: Int,
        fetchedAt: Date,
        appearance: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelTextViewportIdentity requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.documentView = max(1, documentView)
        self.maxView = max(self.documentView, maxView)
        self.fetchedAt = fetchedAt
        self.appearance = appearance
        self.layout = layout
    }
}

package struct NovelTextViewportExternalBlock: Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity?
    public var imageSegmentIdentity: NovelTextSegmentIdentity?
    public var url: URL
    public var chapterOrdinal: Int?
    public var chapterTitle: String?
    public var frozenFrame: NovelTextViewportExternalBlockFrame?
    public var chapterCommentTarget: ReaderChapterCommentTarget?

    public init(
        chapterIdentity: NovelChapterIdentity?,
        imageSegmentIdentity: NovelTextSegmentIdentity? = nil,
        url: URL,
        chapterOrdinal: Int?,
        chapterTitle: String?,
        frozenFrame: NovelTextViewportExternalBlockFrame? = nil,
        chapterCommentTarget: ReaderChapterCommentTarget? = nil
    ) {
        self.chapterIdentity = chapterIdentity
        self.imageSegmentIdentity = imageSegmentIdentity
        self.url = url
        self.chapterOrdinal = chapterOrdinal
        self.chapterTitle = chapterTitle
        self.frozenFrame = frozenFrame
        self.chapterCommentTarget = chapterCommentTarget
    }
}

package struct NovelTextViewportExternalBlockFrame: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
        self.width = max(0, width.isFinite ? width : 0)
        self.height = max(0, height.isFinite ? height : 0)
    }
}

package struct NovelTextViewportDiagnostics: Hashable, Sendable {
    public var indexBuildCount: Int
    public var visibleLayoutPassCount: Int

    public init(
        indexBuildCount: Int,
        visibleLayoutPassCount: Int = 0
    ) {
        self.indexBuildCount = max(0, indexBuildCount)
        self.visibleLayoutPassCount = max(0, visibleLayoutPassCount)
    }
}

package struct NovelTextViewportContext: Hashable, Sendable {
    public var identity: NovelTextViewportIdentity
    public var document: NovelTextViewportDocument
    public var externalBlocks: [NovelTextViewportExternalBlock]
    public var diagnostics: NovelTextViewportDiagnostics

    public init(
        identity: NovelTextViewportIdentity,
        document: NovelTextViewportDocument,
        externalBlocks: [NovelTextViewportExternalBlock],
        diagnostics: NovelTextViewportDiagnostics
    ) {
        self.identity = identity
        self.document = document
        self.externalBlocks = externalBlocks
        self.diagnostics = diagnostics
    }
}
