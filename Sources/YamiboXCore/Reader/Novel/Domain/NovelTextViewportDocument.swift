import Foundation

package struct NovelTextViewportDocument: Hashable, Sendable {
    package let text: String
    package let textRangesBySegment: [Int: NovelDocumentTextRange]
    package let insertedSeparatorRanges: [NovelDocumentTextRange]
    package let inlineTextStylesBySegment: [Int: [NovelRuntimeInlineTextStyle]]
    package let blockTextStyles: [NovelRuntimeBlockTextStyle]
    package let coordinates: NovelTextCoordinateIndex
    package let segmentCoordinates: [Int: NovelTextCoordinateIndex]
    package let sourceCoordinates: [Int: NovelTextCoordinateIndex]
    package let segmentIndexesByIdentity: [NovelTextSegmentIdentity: Int]
    private let orderedRanges: [NovelDocumentTextRange]

    package init(
        text: String,
        textRangesBySegment: [Int: NovelDocumentTextRange],
        insertedSeparatorRanges: [NovelDocumentTextRange],
        inlineTextStylesBySegment: [Int: [NovelRuntimeInlineTextStyle]] = [:],
        blockTextStyles: [NovelRuntimeBlockTextStyle] = [],
        segmentCoordinates: [Int: NovelTextCoordinateIndex],
        sourceCoordinates: [Int: NovelTextCoordinateIndex],
        segmentIndexesByIdentity: [NovelTextSegmentIdentity: Int]
    ) {
        self.text = text
        self.textRangesBySegment = textRangesBySegment
        self.insertedSeparatorRanges = insertedSeparatorRanges
        self.inlineTextStylesBySegment = inlineTextStylesBySegment
        self.blockTextStyles = blockTextStyles
        self.coordinates = NovelTextCoordinateIndex(text)
        self.segmentCoordinates = segmentCoordinates
        self.sourceCoordinates = sourceCoordinates
        self.segmentIndexesByIdentity = segmentIndexesByIdentity
        orderedRanges = textRangesBySegment.values.sorted { $0.startOffset < $1.startOffset }
    }

    // Derived buffers/indexes do not change semantic document identity.
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.textRangesBySegment == rhs.textRangesBySegment &&
            lhs.insertedSeparatorRanges == rhs.insertedSeparatorRanges &&
            lhs.inlineTextStylesBySegment == rhs.inlineTextStylesBySegment &&
            lhs.blockTextStyles == rhs.blockTextStyles &&
            lhs.segmentIndexesByIdentity == rhs.segmentIndexesByIdentity
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(textRangesBySegment)
        hasher.combine(insertedSeparatorRanges)
        hasher.combine(inlineTextStylesBySegment)
        hasher.combine(blockTextStyles)
        hasher.combine(segmentIndexesByIdentity)
    }
}

package extension NovelTextViewportDocument {
    func validateOffsetMap(expectedTextBySegment: [Int: String]) -> Bool {
        guard expectedTextBySegment.count == textRangesBySegment.count else { return false }
        return textRangesBySegment.allSatisfy { segment, range in
            guard let expected = expectedTextBySegment[segment] else { return false }
            return coordinates.text(in: range.startOffset.rawValue..<range.endOffset.rawValue) == expected
        }
    }

    private func firstRangeEnding(atOrAfter offset: NovelDocumentUTF16Offset) -> Int {
        var low = 0
        var high = orderedRanges.count
        while low < high {
            let mid = (low + high) / 2
            if orderedRanges[mid].endOffset < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func surfaceRanges(for surfaceRange: NovelTextViewportDocumentSurfaceRange) -> [NovelRenderedTextRange] {
        guard !surfaceRange.isEmpty else { return [] }
        var result: [NovelRenderedTextRange] = []
        var index = firstRangeEnding(atOrAfter: surfaceRange.startOffset)
        while index < orderedRanges.count {
            let segment = orderedRanges[index]
            guard segment.startOffset < surfaceRange.endOffset else { break }
            let start = max(surfaceRange.startOffset, segment.startOffset)
            let end = min(surfaceRange.endOffset, segment.endOffset)
            if end > start, let coordinates = segmentCoordinates[segment.segmentIndex] {
                result.append(NovelRenderedTextRange(
                    segmentIndex: segment.segmentIndex,
                    startOffset: NovelSegmentUTF16Offset(start - segment.startOffset),
                    endOffset: NovelSegmentUTF16Offset(end - segment.startOffset),
                    coordinates: coordinates
                ))
            }
            index += 1
        }
        return result
    }

    private func segment(containing offset: NovelDocumentUTF16Offset) -> NovelDocumentTextRange? {
        let index = firstRangeEnding(atOrAfter: offset)
        guard orderedRanges.indices.contains(index) else { return nil }
        let range = orderedRanges[index]
        return offset >= range.startOffset && offset <= range.endOffset ? range : nil
    }

    /// Compatibility boundary: Like capture and persisted resume points use Character ordinals.
    func semanticTextPosition(
        containingDocumentOffset documentOffset: NovelDocumentUTF16Offset,
        in projection: NovelReaderProjection
    ) -> NovelTextViewportSemanticTextPosition? {
        guard let range = segment(containing: documentOffset),
              let coordinates = segmentCoordinates[range.segmentIndex],
              let semantics = projection.semantics(forSegmentIndex: range.segmentIndex),
              let identity = semantics.textSegmentIdentity else { return nil }
        return NovelTextViewportSemanticTextPosition(
            chapterIdentity: semantics.chapterIdentity, textSegmentIdentity: identity,
            displayedTextOffset: coordinates.characterOffset(forUTF16Offset: documentOffset - range.startOffset),
            progressInTextRange: 0
        )
    }

    func segmentUTF16Offset(for position: NovelResumePoint) -> NovelSegmentUTF16Offset? {
        guard let identity = position.textSegmentIdentity,
              let segment = segmentIndexesByIdentity[identity],
              let coordinates = segmentCoordinates[segment] else { return nil }
        return NovelSegmentUTF16Offset(coordinates.utf16Offset(forCharacterOffset: position.displayedTextOffset))
    }

    func documentOffset(for position: NovelResumePoint, in projection: NovelReaderProjection) -> NovelDocumentUTF16Offset? {
        guard position.view == projection.view, let identity = position.textSegmentIdentity,
              let segment = segmentIndexesByIdentity[identity],
              let range = textRangesBySegment[segment],
              let offset = segmentUTF16Offset(for: position) else { return nil }
        return range.startOffset + offset.rawValue
    }

    func documentOffset(forSurfaceRange range: NovelRenderedTextRange) -> NovelDocumentUTF16Offset? {
        documentOffsets(forSurfaceRange: range)?.lowerBound
    }

    func documentOffsets(forSurfaceRange range: NovelRenderedTextRange) -> Range<NovelDocumentUTF16Offset>? {
        guard let segment = textRangesBySegment[range.segmentIndex],
              range.startOffset >= 0, range.endOffset >= range.startOffset,
              range.endOffset.rawValue <= segment.length else { return nil }
        return (segment.startOffset + range.startOffset.rawValue)..<(segment.startOffset + range.endOffset.rawValue)
    }

    func text(forSurfaceRange range: NovelRenderedTextRange) -> String? {
        guard let offsets = documentOffsets(forSurfaceRange: range) else { return nil }
        return coordinates.text(in: offsets.lowerBound.rawValue..<offsets.upperBound.rawValue)
    }

    func text(forSurface surface: NovelTextViewportIndexSurface) -> String? {
        var fragments: [String] = []
        for range in surface.ranges {
            guard let fragment = text(forSurfaceRange: range) else { return nil }
            fragments.append(fragment)
        }
        let text = fragments.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    func startsAtParagraphBoundary(surface: NovelTextViewportIndexSurface) -> Bool {
        guard let first = surface.ranges.first, first.startOffset > 0,
              let offset = documentOffset(forSurfaceRange: first) else { return true }
        guard offset.rawValue > 0, offset.rawValue <= coordinates.utf16Count else { return offset == 0 }
        var ordinal = coordinates.characterOffset(forUTF16Offset: offset.rawValue) - 1
        var newlineCount = 0
        while ordinal >= 0, let character = coordinates.character(at: ordinal) {
            if character == "\n" || character == "\r" || character == "\r\n" {
                newlineCount += character == "\r\n" ? 2 : 1
                if newlineCount >= 2 { return true }
            } else if !character.isWhitespace {
                return false
            }
            ordinal -= 1
        }
        return true
    }

    func sample(
        containingDocumentOffset documentOffset: NovelDocumentUTF16Offset,
        surfaceIdentity: NovelReaderSurfaceIdentity,
        documentView: Int,
        in projection: NovelReaderProjection
    ) -> NovelTextViewportSample? {
        guard let range = segment(containing: documentOffset),
              let coordinates = segmentCoordinates[range.segmentIndex],
              let identity = projection.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity else { return nil }
        return NovelTextViewportSample(
            surfaceIdentity: surfaceIdentity, documentView: documentView, textSegmentIdentity: identity,
            displayedTextOffset: NovelSegmentUTF16Offset(coordinates.alignedOffset(documentOffset - range.startOffset)),
            resolvedAuthorID: projection.resolvedAuthorID
        )
    }
}
