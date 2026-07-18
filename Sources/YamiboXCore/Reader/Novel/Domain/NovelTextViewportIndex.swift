import CoreGraphics
import Foundation

package struct NovelRenderedTextRange: Hashable, Sendable {
    public var segmentIndex: Int
    public var startOffset: Int
    public var endOffset: Int

    public init(segmentIndex: Int, startOffset: Int, endOffset: Int) {
        self.segmentIndex = max(0, segmentIndex)
        self.startOffset = max(0, startOffset)
        self.endOffset = max(self.startOffset, endOffset)
    }

    public var length: Int {
        max(endOffset - startOffset, 0)
    }
}

package struct NovelTextViewportIndexSurface: Hashable, Sendable {
    public var surfaceOrdinal: Int
    public var documentView: Int
    public var chapterOrdinal: Int?
    public var chapterTitle: String?
    public var ranges: [NovelRenderedTextRange]
    public var externalBlocks: [NovelTextViewportExternalBlock]
    public var frozenGeometry: NovelTextViewportFrozenGeometry?
    public var chapterCommentTarget: ReaderChapterCommentTarget?

    public init(
        surfaceOrdinal: Int,
        documentView: Int,
        chapterOrdinal: Int?,
        chapterTitle: String?,
        ranges: [NovelRenderedTextRange],
        externalBlocks: [NovelTextViewportExternalBlock] = [],
        frozenGeometry: NovelTextViewportFrozenGeometry? = nil,
        chapterCommentTarget: ReaderChapterCommentTarget? = nil
    ) {
        self.surfaceOrdinal = max(0, surfaceOrdinal)
        self.documentView = max(1, documentView)
        self.chapterOrdinal = chapterOrdinal
        self.chapterTitle = chapterTitle
        self.ranges = ranges
        self.externalBlocks = externalBlocks
        self.frozenGeometry = frozenGeometry
        self.chapterCommentTarget = chapterCommentTarget
    }
}

package struct NovelTextViewportFrozenGeometry: Hashable, Sendable {
    public var documentStartOffset: Int
    public var documentEndOffset: Int
    public var documentClipMinY: CGFloat
    public var documentClipMaxY: CGFloat
    public var contentHeight: CGFloat
    public var pageLocalOriginY: CGFloat

    public init(
        documentStartOffset: Int,
        documentEndOffset: Int,
        documentClipMinY: CGFloat,
        documentClipMaxY: CGFloat,
        contentHeight: CGFloat,
        pageLocalOriginY: CGFloat? = nil
    ) {
        self.documentStartOffset = max(0, documentStartOffset)
        self.documentEndOffset = max(self.documentStartOffset, documentEndOffset)
        let minY = documentClipMinY.isFinite ? documentClipMinY : 0
        let maxY = documentClipMaxY.isFinite ? documentClipMaxY : minY
        self.documentClipMinY = min(minY, maxY)
        self.documentClipMaxY = max(minY, maxY)
        self.contentHeight = max(0, contentHeight.isFinite ? contentHeight : 0)
        self.pageLocalOriginY = pageLocalOriginY ?? self.documentClipMinY
    }

    public var clipHeight: CGFloat {
        max(0, documentClipMaxY - documentClipMinY)
    }

    package static func surfaceContentHeight(forDocumentClipRect clipRect: CGRect) -> CGFloat {
        max(0, clipRect.height.isFinite ? clipRect.height : 0)
    }
}

package struct NovelTextViewportIndexChapter: Hashable, Sendable {
    public var ordinal: Int
    public var title: String
    public var startSurfaceOrdinal: Int
    public var chapterCommentTarget: ReaderChapterCommentTarget?

    public init(
        ordinal: Int,
        title: String,
        startSurfaceOrdinal: Int,
        chapterCommentTarget: ReaderChapterCommentTarget? = nil
    ) {
        self.ordinal = max(0, ordinal)
        self.title = title
        self.startSurfaceOrdinal = max(0, startSurfaceOrdinal)
        self.chapterCommentTarget = chapterCommentTarget
    }
}

package struct NovelTextViewportIndexSurfacePosition: Hashable, Sendable {
    public var surfaceOrdinal: Int
    public var documentView: Int
    public var chapterOrdinal: Int?
    public var chapterTitle: String?
    public var range: NovelRenderedTextRange
    public var chapterCommentTarget: ReaderChapterCommentTarget?

    public init(
        surfaceOrdinal: Int,
        documentView: Int,
        chapterOrdinal: Int?,
        chapterTitle: String?,
        range: NovelRenderedTextRange,
        chapterCommentTarget: ReaderChapterCommentTarget? = nil
    ) {
        self.surfaceOrdinal = max(0, surfaceOrdinal)
        self.documentView = max(1, documentView)
        self.chapterOrdinal = chapterOrdinal
        self.chapterTitle = chapterTitle
        self.range = range
        self.chapterCommentTarget = chapterCommentTarget
    }
}

package struct NovelTextViewportSemanticTextPosition: Hashable, Sendable {
    public var chapterIdentity: NovelChapterIdentity?
    public var textSegmentIdentity: NovelTextSegmentIdentity
    public var displayedTextOffset: Int
    public var progressInTextRange: Double

    public init(
        chapterIdentity: NovelChapterIdentity?,
        textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        progressInTextRange: Double
    ) {
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.displayedTextOffset = max(0, displayedTextOffset)
        self.progressInTextRange = min(max(progressInTextRange, 0), 1)
    }
}

package struct NovelTextViewportSample: Hashable, Sendable {
    public var surfaceIdentity: NovelReaderSurfaceIdentity
    public var documentView: Int
    public var textSegmentIdentity: NovelTextSegmentIdentity
    public var displayedTextOffset: Int
    /// The owning `NovelReaderProjection`'s cache-key identity (see
    /// `NovelTextLikeAnchor.resolvedAuthorID`) — carried on the sample so
    /// Like capture can round-trip the exact cache key later without
    /// guessing it.
    public var resolvedAuthorID: String?

    public init(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        documentView: Int,
        textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        resolvedAuthorID: String? = nil
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.documentView = max(1, documentView)
        self.textSegmentIdentity = textSegmentIdentity
        self.displayedTextOffset = max(0, displayedTextOffset)
        self.resolvedAuthorID = resolvedAuthorID
    }
}

package struct NovelTextViewportIndex: Hashable, Sendable {
    public var documentView: Int
    public var readingMode: ReaderReadingMode
    public var surfaces: [NovelTextViewportIndexSurface]
    public var chapters: [NovelTextViewportIndexChapter]

    public init(
        documentView: Int,
        readingMode: ReaderReadingMode,
        surfaces: [NovelTextViewportIndexSurface],
        chapters: [NovelTextViewportIndexChapter]
    ) {
        self.documentView = max(1, documentView)
        self.readingMode = readingMode
        self.surfaces = surfaces
        self.chapters = chapters
    }

    public func position(
        for textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        in projection: NovelReaderProjection
    ) -> NovelTextViewportIndexSurfacePosition? {
        guard projection.view == documentView,
              let segmentIndex = projection.segmentSemantics.firstIndex(where: {
                  $0?.textSegmentIdentity == textSegmentIdentity
              }) else {
            return nil
        }
        let normalizedSegmentIndex = max(0, segmentIndex)
        let normalizedOffset = max(0, displayedTextOffset)
        for surface in surfaces {
            if let range = surface.ranges.first(where: { range in
                range.segmentIndex == normalizedSegmentIndex && range.contains(offset: normalizedOffset)
            }) {
                return NovelTextViewportIndexSurfacePosition(
                    surfaceOrdinal: surface.surfaceOrdinal,
                    documentView: surface.documentView,
                    chapterOrdinal: surface.chapterOrdinal,
                    chapterTitle: surface.chapterTitle,
                    range: range,
                    chapterCommentTarget: surface.chapterCommentTarget
                )
            }
        }

        let candidates = surfaces.flatMap { surface in
            surface.ranges
                .filter { $0.segmentIndex == normalizedSegmentIndex }
                .map { range in (surface: surface, range: range) }
        }
        guard let nearest = candidates.min(by: {
            $0.range.distance(toOffset: normalizedOffset) < $1.range.distance(toOffset: normalizedOffset)
        }) else {
            return nil
        }
        return NovelTextViewportIndexSurfacePosition(
            surfaceOrdinal: nearest.surface.surfaceOrdinal,
            documentView: nearest.surface.documentView,
            chapterOrdinal: nearest.surface.chapterOrdinal,
            chapterTitle: nearest.surface.chapterTitle,
            range: nearest.range,
            chapterCommentTarget: nearest.surface.chapterCommentTarget
        )
    }
}

package extension NovelTextViewportIndex {
    var novelReaderChapters: [NovelReaderChapter] {
        chapters.map { chapter in
            NovelReaderChapter(
                ordinal: chapter.ordinal,
                title: chapter.title,
                startIndex: chapter.startSurfaceOrdinal,
                chapterCommentTarget: chapter.chapterCommentTarget
            )
        }
    }
}

package extension NovelTextViewportIndexSurface {
    var containsText: Bool {
        !ranges.isEmpty
    }

    func semanticTextPosition(
        for intraSurfaceProgress: Double,
        in projection: NovelReaderProjection
    ) -> NovelTextViewportSemanticTextPosition? {
        guard let rangePosition = textRangePosition(for: intraSurfaceProgress),
              let semantics = projection.semantics(forSegmentIndex: rangePosition.range.segmentIndex),
              let textSegmentIdentity = semantics.textSegmentIdentity else {
            return nil
        }
        let range = rangePosition.range
        let offsetWithinSegment = range.length > 0
            ? Int((Double(range.length) * rangePosition.progressInRange).rounded(.towardZero))
            : 0
        return NovelTextViewportSemanticTextPosition(
            chapterIdentity: semantics.chapterIdentity,
            textSegmentIdentity: textSegmentIdentity,
            displayedTextOffset: range.startOffset + min(offsetWithinSegment, range.length),
            progressInTextRange: rangePosition.progressInRange
        )
    }

    func contains(
        textSegmentIdentity: NovelTextSegmentIdentity,
        in projection: NovelReaderProjection
    ) -> Bool {
        ranges.contains { range in
            projection.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity == textSegmentIdentity
        }
    }

    func contains(
        textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        in projection: NovelReaderProjection
    ) -> Bool {
        ranges.contains { range in
            projection.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity == textSegmentIdentity &&
                range.contains(offset: displayedTextOffset)
        }
    }

    /// External blocks (images) carry their own identity on
    /// `NovelTextViewportExternalBlock.imageSegmentIdentity` rather than in
    /// `ranges`, so a resume point targeting a liked image must be matched
    /// here instead of via the text-range `contains(textSegmentIdentity:)`
    /// overloads above, which only ever see text ranges.
    func contains(
        imageSegmentIdentity: NovelTextSegmentIdentity
    ) -> Bool {
        externalBlocks.contains { $0.imageSegmentIdentity == imageSegmentIdentity }
    }

    func contains(
        chapterIdentity: NovelChapterIdentity,
        in projection: NovelReaderProjection
    ) -> Bool {
        ranges.contains { range in
            projection.semantics(forSegmentIndex: range.segmentIndex)?.chapterIdentity == chapterIdentity
        } || externalBlocks.contains { block in
            block.chapterIdentity == chapterIdentity
        }
    }

    func distance(
        from displayedTextOffset: Int,
        textSegmentIdentity: NovelTextSegmentIdentity,
        in projection: NovelReaderProjection
    ) -> Int {
        let matchingRanges = ranges.filter { range in
            projection.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity == textSegmentIdentity
        }
        guard !matchingRanges.isEmpty else { return Int.max }
        return matchingRanges.map { $0.distance(toOffset: displayedTextOffset) }.min() ?? Int.max
    }

    func intraSurfaceProgress(
        displayedTextOffset: Int,
        textSegmentIdentity: NovelTextSegmentIdentity,
        fallbackProgress: Double,
        in projection: NovelReaderProjection
    ) -> Double {
        progress(
            matching: { range in
                projection.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity == textSegmentIdentity
            },
            offset: displayedTextOffset,
            fallbackProgress: fallbackProgress
        )
    }

    func sample(
        displayOffset: Int,
        in projection: NovelReaderProjection
    ) -> NovelTextViewportSample? {
        guard !ranges.isEmpty else { return nil }
        let normalizedOffset = max(0, displayOffset)
        var runningOffset = 0

        for range in ranges {
            let length = max(range.length, 0)
            let rangeEnd = runningOffset + length
            if normalizedOffset <= rangeEnd {
                guard let textSegmentIdentity = projection
                    .semantics(forSegmentIndex: range.segmentIndex)?
                    .textSegmentIdentity else {
                    return nil
                }
                return NovelTextViewportSample(
                    surfaceIdentity: NovelReaderSurfaceIdentity(
                        generation: 0,
                        ordinal: surfaceOrdinal
                    ),
                    documentView: projection.view,
                    textSegmentIdentity: textSegmentIdentity,
                    displayedTextOffset: range.startOffset + min(max(normalizedOffset - runningOffset, 0), length),
                    resolvedAuthorID: projection.resolvedAuthorID
                )
            }
            runningOffset = rangeEnd + 2
        }

        guard let lastRange = ranges.last,
              let textSegmentIdentity = projection
                  .semantics(forSegmentIndex: lastRange.segmentIndex)?
                  .textSegmentIdentity else {
            return nil
        }
        return NovelTextViewportSample(
            surfaceIdentity: NovelReaderSurfaceIdentity(
                generation: 0,
                ordinal: surfaceOrdinal
            ),
            documentView: projection.view,
            textSegmentIdentity: textSegmentIdentity,
            displayedTextOffset: lastRange.endOffset,
            resolvedAuthorID: projection.resolvedAuthorID
        )
    }

    func displayOffset(
        for textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        in projection: NovelReaderProjection
    ) -> Int? {
        guard let segmentIndex = projection.segmentSemantics.firstIndex(where: {
            $0?.textSegmentIdentity == textSegmentIdentity
        }) else {
            return nil
        }

        var runningOffset = 0
        let normalizedOffset = max(0, displayedTextOffset)

        for range in ranges {
            let length = max(range.length, 0)
            defer { runningOffset += length + 2 }
            guard range.segmentIndex == segmentIndex,
                  normalizedOffset >= range.startOffset,
                  normalizedOffset <= range.endOffset else {
                continue
            }
            return runningOffset + min(max(normalizedOffset - range.startOffset, 0), length)
        }

        return nil
    }

    private func textRangePosition(
        for intraSurfaceProgress: Double
    ) -> (range: NovelRenderedTextRange, progressInRange: Double)? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else {
            return ranges.first.map {
                (range: $0, progressInRange: min(max(intraSurfaceProgress, 0), 1))
            }
        }

        let totalLength = ranges.reduce(0) { $0 + max($1.length, 1) }
        let targetOffset = Int((Double(totalLength) * min(max(intraSurfaceProgress, 0), 1)).rounded(.towardZero))
        var runningLength = 0

        for range in ranges {
            let length = max(range.length, 1)
            if targetOffset < runningLength + length {
                let progressInRange = Double(targetOffset - runningLength) / Double(length)
                return (
                    range: range,
                    progressInRange: min(max(progressInRange, 0), 1)
                )
            }
            runningLength += length
        }

        return ranges.last.map {
            (range: $0, progressInRange: 1)
        }
    }

    private func progress(
        matching predicate: (NovelRenderedTextRange) -> Bool,
        offset: Int,
        fallbackProgress: Double
    ) -> Double {
        guard !ranges.isEmpty else {
            return min(max(fallbackProgress, 0), 1)
        }
        let totalLength = ranges.reduce(0) { $0 + max($1.length, 1) }
        var runningLength = 0

        for range in ranges {
            let length = max(range.length, 1)
            defer { runningLength += length }
            guard predicate(range) else { continue }
            let localOffset = min(max(offset - range.startOffset, 0), length)
            let progress = Double(runningLength + localOffset) / Double(max(totalLength, 1))
            return min(max(progress, 0), 1)
        }

        return min(max(fallbackProgress, 0), 1)
    }
}

package extension NovelTextViewportIndexSurface {
    func nearestTextSample(
        toDocumentOffset documentOffset: Int,
        surfaceIdentity: NovelReaderSurfaceIdentity,
        viewportDocument: NovelTextViewportDocument,
        sourceDocument: NovelReaderProjection
    ) -> NovelTextViewportSample? {
        let candidates = ranges.compactMap { range -> (distance: Int, sample: NovelTextViewportSample)? in
            guard let documentRange = viewportDocument.documentOffsets(forSurfaceRange: range),
                  let semantics = sourceDocument.semantics(forSegmentIndex: range.segmentIndex),
                  let textSegmentIdentity = semantics.textSegmentIdentity else {
                return nil
            }
            let nearestOffset = min(max(documentOffset, documentRange.lowerBound), documentRange.upperBound)
            return (
                abs(documentOffset - nearestOffset),
                NovelTextViewportSample(
                    surfaceIdentity: surfaceIdentity,
                    documentView: documentView,
                    textSegmentIdentity: textSegmentIdentity,
                    displayedTextOffset: nearestOffset - documentRange.lowerBound + range.startOffset,
                    resolvedAuthorID: sourceDocument.resolvedAuthorID
                )
            )
        }

        return candidates.min { $0.distance < $1.distance }?.sample
    }
}

private extension NovelRenderedTextRange {
    func contains(offset: Int) -> Bool {
        if startOffset == endOffset {
            return offset <= startOffset
        }
        return offset >= startOffset && offset < endOffset
    }

    func distance(toOffset offset: Int) -> Int {
        if contains(offset: offset) {
            return 0
        }
        if offset < startOffset {
            return startOffset - offset
        }
        return offset - endOffset
    }
}
