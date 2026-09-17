import Foundation

package struct NovelReaderSearchSurfaceRange: Hashable, Sendable {
    package var startOffset: NovelSegmentUTF16Offset
    package var endOffset: NovelSegmentUTF16Offset
    package var surfaceOrdinal: Int
    package var chapterOrdinal: Int
    package var chapterTitle: String?

    package init(
        startOffset: NovelSegmentUTF16Offset,
        endOffset: NovelSegmentUTF16Offset,
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

    package func contains(_ offset: NovelSegmentUTF16Offset) -> Bool {
        offset >= startOffset && offset < endOffset
    }

    package func distance(to offset: NovelSegmentUTF16Offset) -> Int {
        if contains(offset) { return 0 }
        if offset < startOffset { return startOffset - offset }
        return offset - endOffset
    }
}

package struct NovelReaderSearchSegment: Hashable, Sendable {
    package var text: String
    package let coordinates: NovelTextCoordinateIndex
    package var chapterIdentity: NovelChapterIdentity?
    package var textSegmentIdentity: NovelTextSegmentIdentity
    package var fallbackChapterTitle: String?
    package var surfaceRanges: [NovelReaderSearchSurfaceRange]

    package init(
        text: String,
        coordinates: NovelTextCoordinateIndex,
        chapterIdentity: NovelChapterIdentity?,
        textSegmentIdentity: NovelTextSegmentIdentity,
        fallbackChapterTitle: String?,
        surfaceRanges: [NovelReaderSearchSurfaceRange]
    ) {
        self.text = text
        self.coordinates = coordinates
        self.chapterIdentity = chapterIdentity
        self.textSegmentIdentity = textSegmentIdentity
        self.fallbackChapterTitle = fallbackChapterTitle
        self.surfaceRanges = surfaceRanges
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.chapterIdentity == rhs.chapterIdentity &&
            lhs.textSegmentIdentity == rhs.textSegmentIdentity && lhs.fallbackChapterTitle == rhs.fallbackChapterTitle &&
            lhs.surfaceRanges == rhs.surfaceRanges
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(chapterIdentity)
        hasher.combine(textSegmentIdentity)
        hasher.combine(fallbackChapterTitle)
        hasher.combine(surfaceRanges)
    }

    package func surfaceRange(containing offset: NovelSegmentUTF16Offset) -> NovelReaderSearchSurfaceRange? {
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
    package var displayedTextOffset: NovelSegmentUTF16Offset
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
            let text = segment.text as NSString
            let coordinates = segment.coordinates
            var searchStart = 0

            while searchStart < text.length {
                let match = text.range(of: normalizedQuery, options: [.caseInsensitive, .widthInsensitive],
                                       range: NSRange(location: searchStart, length: text.length - searchStart))
                guard match.location != NSNotFound, match.length > 0, !Task.isCancelled else { break }
                let aligned = coordinates.alignedRange(match.location..<NSMaxRange(match))
                let startOffset = NovelSegmentUTF16Offset(aligned.lowerBound)
                let endOffset = NovelSegmentUTF16Offset(aligned.upperBound)
                let startCharacter = coordinates.characterOffset(forUTF16Offset: aligned.lowerBound)
                let endCharacter = coordinates.characterOffset(forUTF16Offset: aligned.upperBound)
                let surfaceRange = segment.surfaceRange(containing: startOffset)
                let chapterOrdinal = surfaceRange?.chapterOrdinal ?? 0
                let chapterTitle = surfaceRange?.chapterTitle ?? segment.fallbackChapterTitle
                let surfaceOrdinal = surfaceRange?.surfaceOrdinal ?? 0
                let segmentProgress = surfaceRange.map { range in
                    let start = coordinates.characterOffset(forUTF16Offset: range.startOffset.rawValue)
                    let end = coordinates.characterOffset(forUTF16Offset: range.endOffset.rawValue)
                    guard end > start else { return 0.0 }
                    return min(max(Double(startCharacter - start) / Double(end - start), 0), 1)
                } ?? 0
                let startResumePoint = NovelResumePoint(
                    view: snapshot.view,
                    chapterIdentity: segment.chapterIdentity,
                    textSegmentIdentity: segment.textSegmentIdentity,
                    displayedTextOffset: startCharacter,
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
                    displayedTextOffset: endCharacter,
                    chapterOrdinal: chapterOrdinal,
                    chapterTitle: chapterTitle,
                    segmentProgress: segmentProgress,
                    authorID: snapshot.authorID,
                    readingModeHint: snapshot.readingMode
                )
                let excerpt = excerptParts(coordinates: coordinates, start: startCharacter, end: endCharacter)
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

                searchStart = endOffset.rawValue
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
        coordinates: NovelTextCoordinateIndex, start: Int, end: Int
    ) -> (prefix: String, match: String, suffix: String) {
        func slice(_ lower: Int, _ upper: Int) -> String {
            normalizedExcerptText(coordinates.text(
                in: coordinates.utf16Offset(forCharacterOffset: lower)..<coordinates.utf16Offset(forCharacterOffset: upper)
            ) ?? "")
        }
        return (slice(start - excerptRadius, start), slice(start, end), slice(end, end + excerptRadius))
    }

    private static func normalizedExcerptText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
