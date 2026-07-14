import Foundation

package struct NovelTextViewportDocument: Hashable, Sendable {
    public var text: String
    public var textRangesBySegment: [Int: NovelRenderedTextRange]
    public var insertedSeparatorRanges: [NovelRenderedTextRange]
    public var inlineTextStylesBySegment: [Int: [NovelInlineTextStyleRange]]
    public var blockTextStyles: [NovelBlockTextStyleRange]

    public init(
        text: String,
        textRangesBySegment: [Int: NovelRenderedTextRange],
        insertedSeparatorRanges: [NovelRenderedTextRange],
        inlineTextStylesBySegment: [Int: [NovelInlineTextStyleRange]] = [:],
        blockTextStyles: [NovelBlockTextStyleRange] = []
    ) {
        self.text = text
        self.textRangesBySegment = textRangesBySegment
        self.insertedSeparatorRanges = insertedSeparatorRanges
        self.inlineTextStylesBySegment = inlineTextStylesBySegment
        self.blockTextStyles = blockTextStyles
    }
}

package extension NovelTextViewportDocument {
    func validateOffsetMap(
        expectedTextBySegment: [Int: String]
    ) -> Bool {
        guard expectedTextBySegment.count == textRangesBySegment.count else {
            return false
        }
        for (segmentIndex, range) in textRangesBySegment {
            guard let expectedText = expectedTextBySegment[segmentIndex],
                  range.endOffset <= text.count,
                  let start = text.index(
                      text.startIndex,
                      offsetBy: range.startOffset,
                      limitedBy: text.endIndex
                  ),
                  let end = text.index(
                      text.startIndex,
                      offsetBy: range.endOffset,
                      limitedBy: text.endIndex
                  ),
                  String(text[start..<end]) == expectedText else {
                return false
            }
        }
        return true
    }

    func surfaceRanges(
        for surfaceRange: NovelTextViewportDocumentSurfaceRange
    ) -> [NovelRenderedTextRange] {
        let sliceStart = max(0, surfaceRange.startOffset)
        let sliceEnd = max(sliceStart, surfaceRange.endOffset)
        guard sliceEnd > sliceStart else { return [] }

        return textRangesBySegment
            .sorted { $0.value.startOffset < $1.value.startOffset }
            .compactMap { segmentIndex, segmentRange in
                let intersectionStart = max(sliceStart, segmentRange.startOffset)
                let intersectionEnd = min(sliceEnd, segmentRange.endOffset)
                guard intersectionEnd > intersectionStart else { return nil }
                return NovelRenderedTextRange(
                    segmentIndex: segmentIndex,
                    startOffset: intersectionStart - segmentRange.startOffset,
                    endOffset: intersectionEnd - segmentRange.startOffset
                )
            }
    }

    func semanticTextPosition(
        containingDocumentOffset documentOffset: Int,
        in document: NovelReaderProjection
    ) -> NovelTextViewportSemanticTextPosition? {
        guard let segmentRange = textRangesBySegment.first(where: { _, range in
            documentOffset >= range.startOffset && documentOffset <= range.endOffset
        }),
        let semantics = document.semantics(forSegmentIndex: segmentRange.key),
        let textSegmentIdentity = semantics.textSegmentIdentity else {
            return nil
        }

        return NovelTextViewportSemanticTextPosition(
            chapterIdentity: semantics.chapterIdentity,
            textSegmentIdentity: textSegmentIdentity,
            displayedTextOffset: documentOffset - segmentRange.value.startOffset,
            progressInTextRange: 0
        )
    }

    func documentOffset(
        for position: NovelResumePoint,
        in document: NovelReaderProjection
    ) -> Int? {
        guard position.view == document.view,
              let textSegmentIdentity = position.textSegmentIdentity,
              let segmentRange = segmentRange(for: textSegmentIdentity, in: document) else {
            return nil
        }
        return segmentRange.startOffset + min(
            max(position.displayedTextOffset, 0),
            segmentRange.length
        )
    }

    func documentOffset(forSurfaceRange range: NovelRenderedTextRange) -> Int? {
        guard let segmentRange = textRangesBySegment[range.segmentIndex],
              range.startOffset >= 0,
              range.startOffset <= segmentRange.length else {
            return nil
        }
        return segmentRange.startOffset + range.startOffset
    }

    func documentOffsets(forSurfaceRange range: NovelRenderedTextRange) -> Range<Int>? {
        guard let segmentRange = textRangesBySegment[range.segmentIndex],
              range.startOffset >= 0,
              range.endOffset >= range.startOffset,
              range.endOffset <= segmentRange.length else {
            return nil
        }
        return (segmentRange.startOffset + range.startOffset)..<(segmentRange.startOffset + range.endOffset)
    }

    func text(forSurfaceRange range: NovelRenderedTextRange) -> String? {
        guard let documentOffsets = documentOffsets(forSurfaceRange: range),
              documentOffsets.upperBound > documentOffsets.lowerBound,
              documentOffsets.upperBound <= text.count,
              let startIndex = text.index(text.startIndex, offsetBy: documentOffsets.lowerBound, limitedBy: text.endIndex),
              let endIndex = text.index(text.startIndex, offsetBy: documentOffsets.upperBound, limitedBy: text.endIndex) else {
            return nil
        }
        return String(text[startIndex..<endIndex])
    }

    func text(forSurface surface: NovelTextViewportIndexSurface) -> String? {
        var fragments: [String] = []
        for range in surface.ranges {
            guard let fragment = text(forSurfaceRange: range) else {
                return nil
            }
            fragments.append(fragment)
        }
        let text = fragments.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    func startsAtParagraphBoundary(surface: NovelTextViewportIndexSurface) -> Bool {
        guard let firstRange = surface.ranges.first,
              firstRange.startOffset > 0,
              let globalStart = documentOffset(forSurfaceRange: firstRange) else {
            return true
        }
        return isParagraphBoundary(at: globalStart)
    }

    func sample(
        containingDocumentOffset documentOffset: Int,
        surfaceIdentity: NovelReaderSurfaceIdentity,
        documentView: Int,
        in document: NovelReaderProjection
    ) -> NovelTextViewportSample? {
        guard let position = semanticTextPosition(
            containingDocumentOffset: documentOffset,
            in: document
        ) else {
            return nil
        }
        return NovelTextViewportSample(
            surfaceIdentity: surfaceIdentity,
            documentView: documentView,
            textSegmentIdentity: position.textSegmentIdentity,
            displayedTextOffset: position.displayedTextOffset,
            resolvedAuthorID: document.resolvedAuthorID
        )
    }

    private func segmentRange(
        for textSegmentIdentity: NovelTextSegmentIdentity,
        in document: NovelReaderProjection
    ) -> NovelRenderedTextRange? {
        guard let segmentIndex = document.segmentSemantics.firstIndex(where: {
            $0?.textSegmentIdentity == textSegmentIdentity
        }) else {
            return nil
        }
        return textRangesBySegment[segmentIndex]
    }

    private func isParagraphBoundary(at offset: Int) -> Bool {
        guard offset > 0, offset <= text.count else { return offset == 0 }
        let nsText = text as NSString
        var index = offset - 1
        var newlineCount = 0

        while index >= 0 {
            let character = nsText.substring(with: NSRange(location: index, length: 1))
            if character == "\n" || character == "\r" {
                newlineCount += 1
                if newlineCount >= 2 {
                    return true
                }
            } else if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Keep scanning through spaces between the paragraph break and the first visible character.
            } else {
                return false
            }
            index -= 1
        }
        return true
    }
}
