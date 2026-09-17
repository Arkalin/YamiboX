import Foundation
import UIKit
import YamiboXCore

final class NovelTextViewportLayoutDelegate: NSObject, NSTextViewportLayoutControllerDelegate {
    private var viewportBounds: CGRect

    init(viewportBounds: CGRect) {
        self.viewportBounds = viewportBounds
    }

    func updateViewportBounds(_ viewportBounds: CGRect) {
        self.viewportBounds = viewportBounds
    }

    func viewportBounds(
        for textViewportLayoutController: NSTextViewportLayoutController
    ) -> CGRect {
        viewportBounds
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        _ = textLayoutFragment
    }
}

/// Production TextKit 2 runtime adapter: materializes the semantic attributed
/// document into one `NSTextContentStorage`/`NSTextLayoutManager` graph, builds
/// the authoritative viewport index, and hands the graph to Core behind the
/// `NovelTextViewportRuntimeGraph` seam.
final class DefaultNovelTextLayoutRuntimeAdapter: NovelTextLayoutRuntimeAdapter {
    init() {}

    func prepareCandidate(
        input: NovelTextLayoutRuntimeAdapterInput
    ) throws -> NovelTextLayoutRuntimeCandidate {
        let viewportContext = input.preparedInput.viewportContextSeed
        guard !viewportContext.document.text.isEmpty else {
            let result = try input.precomputedResult ?? NovelTextLayout.result(
                from: input.preparedInput,
                surfaceRanges: []
            )
            return NovelTextLayoutRuntimeCandidate(
                result: result,
                fullDocumentLayoutPassCount: 0,
                postIndexCompactionCount: 1,
                ownsAuthoritativeIndex: input.precomputedResult == nil
            )
        }
        let reusesSemanticDocument = input.cachedSemanticAttributedDocument != nil
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let contentWidth = max(input.layout.readableFrame.width, 1)
        let container = NSTextContainer(
            size: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        let attributedDocument: NSAttributedString
        if reusesSemanticDocument, let cached = input.cachedSemanticAttributedDocument {
            attributedDocument = cached
        } else {
            attributedDocument = NovelAttributedTextFactory.makeAttributedDocument(
                from: input.preparedInput
            )
        }
        guard attributedDocument.string == viewportContext.document.text else {
            throw NovelTextLayoutFailure.offsetMapping
        }
        contentStorage.textStorage?.setAttributedString(attributedDocument)
        let surfaceSize = CGSize(
            width: contentWidth,
            height: max(input.layout.readableFrame.height, 1)
        )
        var surfaceRanges = try Self.indexSurfaceRanges(
            attributedDocument: attributedDocument,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            surfaceSize: surfaceSize,
            semanticBreakOffsets: input.settings.readingMode == .paged
                ? Self.semanticSurfaceBreakOffsets(for: input.preparedInput)
                : []
        )
        if input.settings.readingMode == .vertical {
            surfaceRanges = Self.splitSurfaceRangesAtSemanticBreaks(
                surfaceRanges,
                breakOffsets: Self.semanticSurfaceBreakOffsets(for: input.preparedInput),
                attributedDocument: attributedDocument,
                contentStorage: contentStorage,
                layoutManager: layoutManager
            )
        }
        var result = try input.precomputedResult ?? NovelTextLayout.result(
            from: input.preparedInput,
            surfaceRanges: surfaceRanges
        )
        result.fingerprints.font = NovelAttributedTextFactory.resolvedFontFingerprint(
            settings: input.settings
        )
        let platformName = "UIKit"
        result.fingerprints.platform = [
            ProcessInfo.processInfo.operatingSystemVersionString,
            platformName,
        ].joined(separator: "|")
        result.fingerprints.textKitImplementation = "NSTextLayoutManager-TextKit2-UTF16-v2"
        let initialClipRect = surfaceRanges
            .prefix(2)
            .compactMap(\.frozenGeometry)
            .reduce(CGRect.null) { partial, geometry in
                partial.union(
                    CGRect(
                        x: 0,
                        y: geometry.documentClipMinY,
                        width: contentWidth,
                        height: geometry.documentClipMaxY - geometry.documentClipMinY
                    )
                )
            }
        let viewportLayoutController = layoutManager.textViewportLayoutController
        let viewportLayoutDelegate = NovelTextViewportLayoutDelegate(
            viewportBounds: initialClipRect.isNull
                ? CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: contentWidth,
                        height: max(input.layout.readableFrame.height * 2, 1)
                    )
                )
                : initialClipRect
        )
        viewportLayoutController.delegate = viewportLayoutDelegate
        let geometryDeviationCount = try Self.validateRematerializedGeometry(
            surfaceRanges: Array(surfaceRanges.prefix(2)),
            attributedDocument: attributedDocument,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        guard geometryDeviationCount == 0 else {
            throw NovelTextLayoutFailure.geometryValidation
        }
        let graph = NovelTextKitViewportGraph(
            result: result,
            document: input.preparedInput.document,
            settings: input.settings,
            layout: input.layout,
            textContentStorage: contentStorage,
            textLayoutManager: layoutManager,
            textContainer: container,
            textViewportLayoutController: viewportLayoutController,
            textViewportLayoutDelegate: viewportLayoutDelegate
        )
        return NovelTextLayoutRuntimeCandidate(
            result: result,
            semanticAttributedDocument: attributedDocument,
            reusedSemanticAttributedDocument: reusesSemanticDocument,
            fullDocumentLayoutPassCount: 1,
            postIndexCompactionCount: 1,
            geometryDeviationCount: geometryDeviationCount,
            ownsAuthoritativeIndex: input.precomputedResult == nil,
            graph: graph
        )
    }

    private static func indexSurfaceRanges(
        attributedDocument: NSAttributedString,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        surfaceSize: CGSize,
        semanticBreakOffsets: Set<NovelDocumentUTF16Offset> = []
    ) throws -> [NovelTextViewportDocumentSurfaceRange] {
        guard surfaceSize.width >= NovelReaderLayout.minimumTextLayoutWidth, surfaceSize.height > 0 else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        let documentRange = contentStorage.documentRange
        layoutManager.ensureLayout(for: documentRange)

        var segments: [NovelTextSurfaceLayoutFragment] = []
        let documentStart = contentStorage.documentRange.location
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: []
        ) { fragment in
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard fragmentStart != NSNotFound else { return true }
            for lineFragment in fragment.textLineFragments {
                let characterRange = NSRange(
                    location: fragmentStart + lineFragment.characterRange.location,
                    length: lineFragment.characterRange.length
                )
                guard characterRange.location >= 0,
                      characterRange.length > 0,
                      characterRange.location < attributedDocument.length,
                      !lineTextIsPaginationWhitespace(
                          attributedDocument: attributedDocument,
                          characterRange: characterRange
                      ) else {
                    continue
                }
                let lineBounds = lineFragment.typographicBounds
                let rect = CGRect(
                    x: fragment.layoutFragmentFrame.minX + lineBounds.minX,
                    y: fragment.layoutFragmentFrame.minY + lineBounds.minY,
                    width: lineBounds.width,
                    height: lineBounds.height
                ).insetBy(dx: 0, dy: -1)
                guard rect.origin.x.isFinite,
                      rect.origin.y.isFinite,
                      rect.width.isFinite,
                      rect.height.isFinite,
                      rect.height > 0 else {
                    continue
                }
                segments.append(
                    NovelTextSurfaceLayoutFragment(
                        characterRange: characterRange,
                        rect: rect
                    )
                )
            }
            return true
        }

        let breakOffsets = Set(semanticBreakOffsets.map(\.rawValue))
        let ranges = NovelTextSurfaceFragmentPartitioner.partition(
            segments,
            surfaceHeight: surfaceSize.height,
            breakOffsets: breakOffsets
        ).compactMap { page in
            viewportDocumentPageRange(
                from: attributedDocument,
                range: page.characterRange,
                clipRect: page.clipRect
            )
        }
        guard attributedDocument.length == 0 || !ranges.isEmpty else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return ranges
    }

    private static func semanticSurfaceBreakOffsets(
        for input: NovelTextLayoutPreparedInput
    ) -> Set<NovelDocumentUTF16Offset> {
        var breakOffsets = Set<NovelDocumentUTF16Offset>()
        var previousTextSegment: NovelAnnotatedSegment?
        var sawImageSincePreviousText = false
        let viewportDocument = input.viewportContextSeed.document

        for annotatedSegment in input.annotatedSegments {
            switch annotatedSegment.segment {
            case .image:
                if previousTextSegment != nil {
                    sawImageSincePreviousText = true
                }

            case .text:
                defer {
                    previousTextSegment = annotatedSegment
                    sawImageSincePreviousText = false
                }
                guard let previousTextSegment else { continue }
                let chapterChanged = previousTextSegment.chapterOrdinal != annotatedSegment.chapterOrdinal ||
                    previousTextSegment.chapterTitle != annotatedSegment.chapterTitle
                guard sawImageSincePreviousText || chapterChanged,
                      let range = viewportDocument.textRangesBySegment[annotatedSegment.index],
                      range.startOffset > 0 else {
                    continue
                }
                breakOffsets.insert(range.startOffset)
            }
        }

        return breakOffsets
    }

    private static func splitSurfaceRangesAtSemanticBreaks(
        _ surfaceRanges: [NovelTextViewportDocumentSurfaceRange],
        breakOffsets: Set<NovelDocumentUTF16Offset>,
        attributedDocument: NSAttributedString,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) -> [NovelTextViewportDocumentSurfaceRange] {
        guard !surfaceRanges.isEmpty, !breakOffsets.isEmpty else { return surfaceRanges }
        var splitRanges: [NovelTextViewportDocumentSurfaceRange] = []

        for surfaceRange in surfaceRanges {
            let cuts = ([surfaceRange.startOffset] + breakOffsets.filter {
                $0 > surfaceRange.startOffset && $0 < surfaceRange.endOffset
            }.sorted() + [surfaceRange.endOffset])
            guard cuts.count > 2 else {
                splitRanges.append(surfaceRange)
                continue
            }

            for index in 0..<(cuts.count - 1) {
                let startOffset = cuts[index]
                let endOffset = cuts[index + 1]
                guard let clipRect = lineClipRect(
                    startOffset: startOffset.rawValue,
                    endOffset: endOffset.rawValue,
                    attributedDocument: attributedDocument,
                    contentStorage: contentStorage,
                    layoutManager: layoutManager
                ),
                    let splitRange = viewportDocumentPageRange(
                        from: attributedDocument,
                        range: NSRange(location: startOffset.rawValue, length: endOffset - startOffset),
                        clipRect: clipRect
                    ) else {
                    continue
                }
                splitRanges.append(splitRange)
            }
        }

        return splitRanges.isEmpty ? surfaceRanges : splitRanges
    }

    private static func lineClipRect(
        startOffset: Int,
        endOffset: Int,
        attributedDocument: NSAttributedString,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) -> CGRect? {
        guard startOffset >= 0, endOffset > startOffset,
              let startLocation = contentStorage.location(
                contentStorage.documentRange.location,
                offsetBy: startOffset
              ) else {
            return nil
        }

        let documentStart = contentStorage.documentRange.location
        var clipRect = CGRect.null
        layoutManager.enumerateTextLayoutFragments(
            from: startLocation,
            options: []
        ) { fragment in
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard fragmentStart != NSNotFound else { return false }
            var shouldContinue = true
            for lineFragment in fragment.textLineFragments {
                let lineStart = fragmentStart + lineFragment.characterRange.location
                let lineEnd = lineStart + lineFragment.characterRange.length
                if lineStart >= endOffset {
                    shouldContinue = false
                    break
                }
                guard lineStart >= startOffset, lineEnd > lineStart else {
                    continue
                }
                guard !lineTextIsPaginationWhitespace(
                    attributedDocument: attributedDocument,
                    characterRange: NSRange(location: lineStart, length: lineFragment.characterRange.length)
                ) else {
                    continue
                }
                let lineBounds = lineFragment.typographicBounds
                let rect = CGRect(
                    x: fragment.layoutFragmentFrame.minX + lineBounds.minX,
                    y: fragment.layoutFragmentFrame.minY + lineBounds.minY,
                    width: lineBounds.width,
                    height: lineBounds.height
                ).insetBy(dx: 0, dy: -1)
                guard rect.origin.x.isFinite,
                      rect.origin.y.isFinite,
                      rect.width.isFinite,
                      rect.height.isFinite,
                      rect.height > 0 else {
                    continue
                }
                clipRect = clipRect.union(rect)
            }
            return shouldContinue
        }
        return clipRect.isNull ? nil : clipRect
    }

    private static func validateRematerializedGeometry(
        surfaceRanges: [NovelTextViewportDocumentSurfaceRange],
        attributedDocument: NSAttributedString,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) throws -> Int {
        let documentStart = contentStorage.documentRange.location
        var deviationCount = 0
        for surfaceRange in surfaceRanges {
            guard let geometry = surfaceRange.frozenGeometry,
                  let start = contentStorage.location(
                      documentStart,
                      offsetBy: surfaceRange.startOffset.rawValue
                  ),
                  let end = contentStorage.location(
                      start,
                      offsetBy: surfaceRange.endOffset - surfaceRange.startOffset
                  ),
                  let textRange = NSTextRange(location: start, end: end) else {
                throw NovelTextLayoutFailure.geometryValidation
            }
            var rematerializedRect = CGRect.null
            layoutManager.enumerateTextSegments(
                in: textRange,
                type: .standard,
                options: []
            ) { _, rect, _, _ in
                if rect.width.isFinite, rect.height.isFinite, rect.height > 0 {
                    rematerializedRect = rematerializedRect.union(rect)
                }
                return true
            }
            let tolerance: CGFloat = 1
            if rematerializedRect.isNull ||
                rematerializedRect.minY < geometry.documentClipMinY - tolerance ||
                rematerializedRect.maxY - geometry.documentClipMaxY > tolerance {
                deviationCount += 1
            }
        }
        return deviationCount
    }

    private static func viewportDocumentPageRange(
        from attributedText: NSAttributedString,
        range: NSRange,
        clipRect: CGRect
    ) -> NovelTextViewportDocumentSurfaceRange? {
        let text = attributedText.string
        let textLength = attributedText.length
        let pageUTF16Start = max(0, min(range.location, textLength))
        let nextUTF16End = min(range.location + range.length, textLength)
        let trimmedEnd = max(
            trimmedUTF16Boundary(in: text, from: pageUTF16Start, to: nextUTF16End),
            pageUTF16Start
        )
        guard trimmedEnd > pageUTF16Start else { return nil }

        let candidateText = attributedText.attributedSubstring(
            from: NSRange(location: pageUTF16Start, length: trimmedEnd - pageUTF16Start)
        ).string
        let trimmedLeadingText = trimmingLeadingPaginationWhitespace(candidateText)
        let leadingTrimmed = candidateText.utf16.count - trimmedLeadingText.utf16.count
        let effectiveStart = pageUTF16Start + leadingTrimmed
        guard effectiveStart < trimmedEnd else { return nil }
        let documentStart = NovelDocumentUTF16Offset(effectiveStart)
        let documentEnd = NovelDocumentUTF16Offset(trimmedEnd)

        return NovelTextViewportDocumentSurfaceRange(
            startOffset: documentStart,
            endOffset: documentEnd,
            frozenGeometry: NovelTextViewportFrozenGeometry(
                documentStartOffset: documentStart,
                documentEndOffset: documentEnd,
                documentClipMinY: clipRect.minY,
                documentClipMaxY: clipRect.maxY,
                contentHeight: NovelTextViewportFrozenGeometry.surfaceContentHeight(
                    forDocumentClipRect: clipRect
                )
            )
        )
    }

    private static func lineTextIsPaginationWhitespace(
        attributedDocument: NSAttributedString,
        characterRange: NSRange
    ) -> Bool {
        let safeRange = NSRange(
            location: max(0, min(characterRange.location, attributedDocument.length)),
            length: max(0, min(characterRange.length, attributedDocument.length - max(0, min(characterRange.location, attributedDocument.length))))
        )
        guard safeRange.length > 0 else { return true }
        return attributedDocument.attributedSubstring(from: safeRange)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func trimmedUTF16Boundary(
        in text: String,
        from start: Int,
        to candidateEnd: Int
    ) -> Int {
        guard candidateEnd > start else { return start }
        let nsText = text as NSString
        var end = candidateEnd
        while end > start {
            let character = nsText.substring(with: NSRange(location: end - 1, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    private static func trimmingLeadingPaginationWhitespace(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text[...]
        while let first = result.first, first.isWhitespace {
            result.removeFirst()
        }
        return String(result)
    }
}
