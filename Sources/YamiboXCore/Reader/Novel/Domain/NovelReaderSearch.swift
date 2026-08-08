import Foundation

package struct NovelReaderSearchSurfaceRange: Hashable, Sendable {
    package var startOffset: Int
    package var endOffset: Int
    package var surfaceOrdinal: Int
    package var chapterOrdinal: Int
    package var chapterTitle: String?

    package init(
        startOffset: Int,
        endOffset: Int,
        surfaceOrdinal: Int,
        chapterOrdinal: Int,
        chapterTitle: String?
    ) {
        self.startOffset = max(0, startOffset)
        self.endOffset = max(self.startOffset, endOffset)
        self.surfaceOrdinal = max(0, surfaceOrdinal)
        self.chapterOrdinal = max(0, chapterOrdinal)
        self.chapterTitle = chapterTitle
    }

    package func contains(_ offset: Int) -> Bool {
        offset >= startOffset && offset < endOffset
    }

    package func distance(to offset: Int) -> Int {
        if contains(offset) { return 0 }
        if offset < startOffset { return startOffset - offset }
        return offset - endOffset
    }
}

package struct NovelReaderSearchSegment: Hashable, Sendable {
    package var text: String
    package var chapterIdentity: NovelChapterIdentity?
    package var textSegmentIdentity: NovelTextSegmentIdentity
    package var fallbackChapterTitle: String?
    package var surfaceRanges: [NovelReaderSearchSurfaceRange]

    package init(
        text: String,
        chapterIdentity: NovelChapterIdentity?,
        textSegmentIdentity: NovelTextSegmentIdentity,
        fallbackChapterTitle: String?,
        surfaceRanges: [NovelReaderSearchSurfaceRange]
    ) {
        self.text = text
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.fallbackChapterTitle = fallbackChapterTitle
        self.surfaceRanges = surfaceRanges
    }

    package func surfaceRange(containing offset: Int) -> NovelReaderSearchSurfaceRange? {
        surfaceRanges.first(where: { $0.contains(offset) })
            ?? surfaceRanges.min(by: { $0.distance(to: offset) < $1.distance(to: offset) })
    }
}

package struct NovelReaderSearchSnapshot: Hashable, Sendable {
    package var generation: UInt64
    package var view: Int
    package var authorID: String?
    package var readingMode: ReaderReadingMode
    package var surfaceCount: Int
    package var segments: [NovelReaderSearchSegment]

    package init(
        generation: UInt64,
        view: Int,
        authorID: String?,
        readingMode: ReaderReadingMode,
        surfaceCount: Int,
        segments: [NovelReaderSearchSegment]
    ) {
        self.generation = generation
        self.view = max(1, view)
        self.authorID = authorID
        self.readingMode = readingMode
        self.surfaceCount = max(1, surfaceCount)
        self.segments = segments
    }
}

package struct NovelReaderSearchMatchID: Hashable, Sendable {
    package var generation: UInt64
    package var textSegmentIdentity: NovelTextSegmentIdentity
    package var displayedTextOffset: Int
}

package struct NovelReaderSearchMatch: Identifiable, Hashable, Sendable {
    package var id: NovelReaderSearchMatchID
    package var chapterTitle: String?
    package var positionLabel: String
    package var excerptPrefix: String
    package var matchedText: String
    package var excerptSuffix: String
    package var startResumePoint: NovelResumePoint
    package var endResumePoint: NovelResumePoint

    package init(
        id: NovelReaderSearchMatchID,
        chapterTitle: String?,
        positionLabel: String,
        excerptPrefix: String,
        matchedText: String,
        excerptSuffix: String,
        startResumePoint: NovelResumePoint,
        endResumePoint: NovelResumePoint
    ) {
        self.id = id
        self.chapterTitle = chapterTitle
        self.positionLabel = positionLabel
        self.excerptPrefix = excerptPrefix
        self.matchedText = matchedText
        self.excerptSuffix = excerptSuffix
        self.startResumePoint = startResumePoint
        self.endResumePoint = endResumePoint
    }
}

package enum NovelReaderSearchEngine {
    private static let excerptRadius = 56

    package static func search(
        snapshot: NovelReaderSearchSnapshot,
        query: String,
        onMatch: @escaping @Sendable (NovelReaderSearchMatch) async -> Void
    ) async {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return }

        for segment in snapshot.segments {
            guard !Task.isCancelled else { return }
            var searchStart = segment.text.startIndex

            while searchStart < segment.text.endIndex,
                  let matchRange = segment.text.range(
                      of: normalizedQuery,
                      options: [.caseInsensitive, .widthInsensitive],
                      range: searchStart..<segment.text.endIndex
                  ) {
                guard !Task.isCancelled else { return }
                let startOffset = segment.text.distance(from: segment.text.startIndex, to: matchRange.lowerBound)
                let matchLength = segment.text.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
                guard matchLength > 0 else { return }
                let surfaceRange = segment.surfaceRange(containing: startOffset)
                let chapterOrdinal = surfaceRange?.chapterOrdinal ?? 0
                let chapterTitle = surfaceRange?.chapterTitle ?? segment.fallbackChapterTitle
                let surfaceOrdinal = surfaceRange?.surfaceOrdinal ?? 0
                let segmentProgress = surfaceRange.map { range in
                    guard range.endOffset > range.startOffset else { return 0.0 }
                    return min(
                        max(Double(startOffset - range.startOffset) / Double(range.endOffset - range.startOffset), 0),
                        1
                    )
                } ?? 0
                let startResumePoint = NovelResumePoint(
                    view: snapshot.view,
                    chapterIdentity: segment.chapterIdentity,
                    textSegmentIdentity: segment.textSegmentIdentity,
                    displayedTextOffset: startOffset,
                    chapterOrdinal: chapterOrdinal,
                    chapterTitle: chapterTitle,
                    segmentProgress: segmentProgress,
                    authorID: snapshot.authorID,
                    readingModeHint: snapshot.readingMode
                )
                let endResumePoint = NovelResumePoint(
                    view: snapshot.view,
                    chapterIdentity: segment.chapterIdentity,
                    textSegmentIdentity: segment.textSegmentIdentity,
                    displayedTextOffset: startOffset + matchLength,
                    chapterOrdinal: chapterOrdinal,
                    chapterTitle: chapterTitle,
                    segmentProgress: segmentProgress,
                    authorID: snapshot.authorID,
                    readingModeHint: snapshot.readingMode
                )
                let excerpt = excerptParts(in: segment.text, matchRange: matchRange)
                await onMatch(NovelReaderSearchMatch(
                    id: NovelReaderSearchMatchID(
                        generation: snapshot.generation,
                        textSegmentIdentity: segment.textSegmentIdentity,
                        displayedTextOffset: startOffset
                    ),
                    chapterTitle: chapterTitle,
                    positionLabel: positionLabel(
                        surfaceOrdinal: surfaceOrdinal,
                        surfaceCount: snapshot.surfaceCount,
                        readingMode: snapshot.readingMode
                    ),
                    excerptPrefix: excerpt.prefix,
                    matchedText: excerpt.match,
                    excerptSuffix: excerpt.suffix,
                    startResumePoint: startResumePoint,
                    endResumePoint: endResumePoint
                ))

                searchStart = matchRange.upperBound
                await Task.yield()
            }
        }
    }

    private static func positionLabel(
        surfaceOrdinal: Int,
        surfaceCount: Int,
        readingMode: ReaderReadingMode
    ) -> String {
        switch readingMode {
        case .paged:
            return String(min(max(surfaceOrdinal + 1, 1), max(surfaceCount, 1)))
        case .vertical:
            guard surfaceCount > 1 else { return "0%" }
            let fraction = Double(min(max(surfaceOrdinal, 0), surfaceCount - 1)) / Double(surfaceCount - 1)
            return "\(Int((fraction * 100).rounded()))%"
        }
    }

    private static func excerptParts(
        in text: String,
        matchRange: Range<String.Index>
    ) -> (prefix: String, match: String, suffix: String) {
        let prefixStart = text.index(
            matchRange.lowerBound,
            offsetBy: -excerptRadius,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let suffixEnd = text.index(
            matchRange.upperBound,
            offsetBy: excerptRadius,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return (
            normalizedExcerptText(String(text[prefixStart..<matchRange.lowerBound])),
            normalizedExcerptText(String(text[matchRange])),
            normalizedExcerptText(String(text[matchRange.upperBound..<suffixEnd]))
        )
    }

    private static func normalizedExcerptText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
