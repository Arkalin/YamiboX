import CoreGraphics
import Foundation

typealias NovelTextViewportSurfaceLayout = @Sendable (
    _ viewportContext: NovelTextViewportContext,
    _ settings: NovelReaderAppearanceSettings,
    _ layout: NovelReaderLayout
) -> [NovelTextViewportDocumentSurfaceRange]

package struct NovelTextLayoutPreparedInput: Sendable {
    package let document: NovelReaderProjection
    package let settings: NovelReaderAppearanceSettings
    package let layout: NovelReaderLayout
    package let annotatedSegments: [NovelAnnotatedSegment]
    package let viewportContextSeed: NovelTextViewportContext
}

public enum NovelTextLayoutFailureStage: String, Equatable, Sendable {
    case semanticDocumentPreparation
    case offsetMapping
    case textKitIndexing
    case geometryValidation
    case externalBlockProjection
}

public enum NovelTextLayoutFailure: LocalizedError, Equatable, Sendable {
    case semanticDocumentPreparation
    case offsetMapping
    case textKitIndexing
    case geometryValidation
    case externalBlockProjection

    public var stage: NovelTextLayoutFailureStage {
        switch self {
        case .semanticDocumentPreparation:
            return .semanticDocumentPreparation
        case .offsetMapping:
            return .offsetMapping
        case .textKitIndexing:
            return .textKitIndexing
        case .geometryValidation:
            return .geometryValidation
        case .externalBlockProjection:
            return .externalBlockProjection
        }
    }

    public var errorDescription: String? {
        switch self {
        case .semanticDocumentPreparation:
            return "Novel Text Layout could not prepare the semantic document."
        case .offsetMapping:
            return "Novel Text Layout could not map semantic text offsets."
        case .textKitIndexing:
            return "Novel Text Layout could not build the TextKit index."
        case .geometryValidation:
            return "Novel Text Layout geometry validation failed."
        case .externalBlockProjection:
            return "Novel Text Layout could not project an external block."
        }
    }
}

public enum NovelTextLayout {
    package static func prepareInput(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) throws -> NovelTextLayoutPreparedInput {
        let annotatedSegments = annotatedSegments(from: document, settings: settings)
        guard annotatedSegments.contains(where: { annotatedSegment in
            switch annotatedSegment.segment {
            case let .text(text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image:
                return true
            }
        }) else {
            throw NovelTextLayoutFailure.semanticDocumentPreparation
        }
        let viewportContext = makeViewportContext(
            annotatedSegments: annotatedSegments,
            document: document,
            settings: settings,
            layout: layout
        )
        try validateOffsetMap(
            annotatedSegments: annotatedSegments,
            viewportDocument: viewportContext.document
        )
        return NovelTextLayoutPreparedInput(
            document: document,
            settings: settings,
            layout: layout,
            annotatedSegments: annotatedSegments,
            viewportContextSeed: viewportContext
        )
    }

    package static func result(
        from preparedInput: NovelTextLayoutPreparedInput,
        surfaceRanges: [NovelTextViewportDocumentSurfaceRange]
    ) throws -> NovelTextLayoutResult {
        let result = try render(
            annotatedSegments: preparedInput.annotatedSegments,
            document: preparedInput.document,
            settings: preparedInput.settings,
            layout: preparedInput.layout,
            viewportContextSeed: preparedInput.viewportContextSeed,
            viewportSurfaceLayout: { _, _, _ in surfaceRanges }
        )
        let hasVisibleText = result.viewportIndex.surfaces.contains { !$0.ranges.isEmpty }
        let hasInputText = hasDisplayableText(in: preparedInput.annotatedSegments)
        guard !hasInputText || hasVisibleText else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return result
    }

    static func viewportSample(
        displayOffset: Int,
        ranges: [NovelRenderedTextRange],
        document: NovelReaderProjection,
        surfaceOrdinal: Int
    ) -> NovelTextViewportSample? {
        NovelTextViewportIndexSurface(
            surfaceOrdinal: surfaceOrdinal,
            documentView: document.view,
            chapterOrdinal: nil,
            chapterTitle: nil,
            ranges: ranges,
            externalBlocks: []
        )
        .sample(displayOffset: displayOffset, in: document)
    }

    static func displayOffset(
        for textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        in document: NovelReaderProjection,
        ranges: [NovelRenderedTextRange]
    ) -> Int? {
        NovelTextViewportIndexSurface(
            surfaceOrdinal: 0,
            documentView: document.view,
            chapterOrdinal: nil,
            chapterTitle: nil,
            ranges: ranges,
            externalBlocks: []
        )
        .displayOffset(
            for: textSegmentIdentity,
            displayedTextOffset: displayedTextOffset,
            in: document
        )
    }

    static func layout(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        viewportSurfaceLayout: NovelTextViewportSurfaceLayout
    ) throws -> NovelTextLayoutResult {
        let preparedInput = try prepareInput(
            document: document,
            settings: settings,
            layout: layout
        )
        let result = try render(
            annotatedSegments: preparedInput.annotatedSegments,
            document: document,
            settings: settings,
            layout: layout,
            viewportContextSeed: preparedInput.viewportContextSeed,
            viewportSurfaceLayout: viewportSurfaceLayout
        )
        let hasVisibleText = result.viewportIndex.surfaces.contains { !$0.ranges.isEmpty }
        let hasInputText = hasDisplayableText(in: preparedInput.annotatedSegments)
        guard !hasInputText || hasVisibleText else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        return result
    }

    /// Whether the segments we actually intend to display (post
    /// `showsAuthorRepliesToOthers`/`loadsInlineImages` filtering) include
    /// non-whitespace text. Deliberately checks `annotatedSegments`, not the
    /// document's raw, unfiltered `segments` — a page whose only text is
    /// hidden by a display setting has no displayable text at all, so a
    /// resulting image-only (or empty) render is correct, not a TextKit
    /// failure. Using the raw segments here previously made any page where
    /// every text segment was filtered out (e.g. all author replies to
    /// others, with `showsAuthorRepliesToOthers` off) throw
    /// `.textKitIndexing`, even though nothing was actually broken.
    private static func hasDisplayableText(in annotatedSegments: [NovelAnnotatedSegment]) -> Bool {
        annotatedSegments.contains { !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func render(
        annotatedSegments: [NovelAnnotatedSegment],
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        viewportContextSeed: NovelTextViewportContext,
        viewportSurfaceLayout: (NovelTextViewportContext, NovelReaderAppearanceSettings, NovelReaderLayout) throws -> [NovelTextViewportDocumentSurfaceRange]
    ) throws -> NovelTextLayoutResult {
        var indexSurfaces: [NovelTextViewportIndexSurface] = []
        var chapters: [NovelTextViewportIndexChapter] = []
        var seenChapterOrdinals = Set<Int>()
        let annotatedSegmentByIndex = Dictionary(
            uniqueKeysWithValues: annotatedSegments.map { ($0.index, $0) }
        )
        let imageSegmentIndexes = Set(annotatedSegments.compactMap { annotatedSegment in
            if case .image = annotatedSegment.segment {
                return annotatedSegment.index
            }
            return nil
        })
        var surfaceDrafts: [NovelViewportSurfaceDraft] = []
        var nextDraftOrdinal = 0

        if !viewportContextSeed.document.text.isEmpty {
            let surfaceRanges = try viewportSurfaceLayout(viewportContextSeed, settings, layout)
            for surfaceRange in surfaceRanges where !surfaceRange.isEmpty {
                let ranges = segmentRanges(
                    for: surfaceRange,
                    viewportDocument: viewportContextSeed.document
                )
                for group in splitTextRanges(
                    ranges,
                    aroundImageSegmentIndexes: imageSegmentIndexes,
                    annotatedSegmentByIndex: annotatedSegmentByIndex,
                    document: document
                ) where !group.isEmpty {
                    surfaceDrafts.append(
                        NovelViewportSurfaceDraft(
                            orderSegmentIndex: group[0].segmentIndex,
                            ordinal: nextDraftOrdinal,
                            kind: .text(group, frozenGeometry: surfaceRange.frozenGeometry)
                        )
                    )
                    nextDraftOrdinal += 1
                }
            }
        }

        for annotatedSegment in annotatedSegments {
            switch annotatedSegment.segment {
            case .text:
                continue

            case let .image(url, chapterTitle):
                let externalBlock = NovelTextViewportExternalBlock(
                    chapterIdentity: annotatedSegment.semantics?.chapterIdentity,
                    imageSegmentIdentity: annotatedSegment.semantics?.textSegmentIdentity,
                    url: url,
                    chapterOrdinal: annotatedSegment.chapterOrdinal,
                    chapterTitle: annotatedSegment.chapterTitle,
                    frozenFrame: frozenExternalBlockFrame(layout: layout),
                    chapterCommentTarget: chapterCommentTarget(for: annotatedSegment, document: document)
                )
                guard let frame = externalBlock.frozenFrame,
                      frame.width.isFinite,
                      frame.height.isFinite,
                      frame.width > 0,
                      frame.height > 0 else {
                    throw NovelTextLayoutFailure.externalBlockProjection
                }
                surfaceDrafts.append(
                    NovelViewportSurfaceDraft(
                        orderSegmentIndex: annotatedSegment.index,
                        ordinal: nextDraftOrdinal,
                        kind: .image(url: url, chapterTitle: chapterTitle, externalBlock: externalBlock)
                    )
                )
                nextDraftOrdinal += 1
            }
        }

        for draft in surfaceDrafts.sorted(by: {
            if $0.orderSegmentIndex != $1.orderSegmentIndex {
                return $0.orderSegmentIndex < $1.orderSegmentIndex
            }
            return $0.ordinal < $1.ordinal
        }) {
            switch draft.kind {
            case let .text(ranges, frozenGeometry):
                guard let firstRange = ranges.first,
                      let annotatedSegment = annotatedSegmentByIndex[firstRange.segmentIndex] else {
                    continue
                }
                let surface = NovelTextViewportIndexSurface(
                    surfaceOrdinal: indexSurfaces.count,
                    documentView: document.view,
                    chapterOrdinal: annotatedSegment.chapterOrdinal,
                    chapterTitle: annotatedSegment.chapterTitle,
                    ranges: ranges,
                    externalBlocks: [],
                    frozenGeometry: frozenGeometry,
                    chapterCommentTarget: chapterCommentTarget(for: annotatedSegment, document: document)
                )
                for range in ranges {
                    guard let rangeSegment = annotatedSegmentByIndex[range.segmentIndex],
                          let chapterOrdinal = rangeSegment.chapterOrdinal,
                          let chapterTitle = rangeSegment.chapterTitle,
                          seenChapterOrdinals.insert(chapterOrdinal).inserted else {
                        continue
                    }
                    chapters.append(
                        NovelTextViewportIndexChapter(
                            ordinal: chapterOrdinal,
                            title: chapterTitle,
                            startSurfaceOrdinal: surface.surfaceOrdinal,
                            chapterCommentTarget: chapterCommentTarget(for: rangeSegment, document: document)
                        )
                    )
                }
                indexSurfaces.append(surface)

            case let .image(_, _, externalBlock):
                let surface = NovelTextViewportIndexSurface(
                    surfaceOrdinal: indexSurfaces.count,
                    documentView: document.view,
                    chapterOrdinal: externalBlock.chapterOrdinal,
                    chapterTitle: externalBlock.chapterTitle,
                    ranges: [],
                    externalBlocks: [externalBlock],
                    chapterCommentTarget: externalBlock.chapterCommentTarget
                )
                if let chapterOrdinal = externalBlock.chapterOrdinal,
                   let chapterTitle = externalBlock.chapterTitle,
                   seenChapterOrdinals.insert(chapterOrdinal).inserted {
                    chapters.append(
                        NovelTextViewportIndexChapter(
                            ordinal: chapterOrdinal,
                            title: chapterTitle,
                            startSurfaceOrdinal: surface.surfaceOrdinal,
                            chapterCommentTarget: surface.chapterCommentTarget
                        )
                    )
                }
                indexSurfaces.append(surface)
            }
        }

        guard !indexSurfaces.isEmpty else {
            throw NovelTextLayoutFailure.textKitIndexing
        }

        let viewportIndex = NovelTextViewportIndex(
            documentView: document.view,
            readingMode: settings.readingMode,
            surfaces: indexSurfaces,
            chapters: chapters
        )
        let viewportContext = NovelTextViewportContext(
            identity: viewportContextSeed.identity,
            document: viewportContextSeed.document,
            externalBlocks: viewportContextSeed.externalBlocks,
            diagnostics: NovelTextViewportDiagnostics(
                indexBuildCount: viewportContextSeed.diagnostics.indexBuildCount,
                visibleLayoutPassCount: viewportContextSeed.diagnostics.visibleLayoutPassCount
            )
        )

        return NovelTextLayoutResult(
            viewportContext: viewportContext,
            viewportIndex: viewportIndex,
            layoutMetrics: layoutMetrics(
                viewportIndex: viewportIndex,
                layout: layout
            ),
            fingerprints: fingerprints(
                annotatedSegments: annotatedSegments,
                viewportDocument: viewportContext.document,
                settings: settings,
                layout: layout
            )
        )
    }

    private static func fingerprints(
        annotatedSegments: [NovelAnnotatedSegment],
        viewportDocument: NovelTextViewportDocument,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) -> NovelTextLayoutFingerprints {
        let semanticPayload = annotatedSegments.map { segment in
            let inlineStyles = (segment.semantics?.inlineTextStyles ?? []).map { inlineStyle in
                [
                    inlineStyle.style.rawValue,
                    String(inlineStyle.range.location),
                    String(inlineStyle.range.length),
                ].joined(separator: ":")
            }.joined(separator: ",")
            let blockStyles = (segment.semantics?.blockTextStyles ?? []).map { blockStyle in
                [
                    blockStyle.style.rawValue,
                    String(blockStyle.range.location),
                    String(blockStyle.range.length),
                ].joined(separator: ":")
            }.joined(separator: ",")
            return [
                String(segment.index),
                segment.semantics?.chapterIdentity?.rawValue ?? "",
                segment.semantics?.textSegmentIdentity?.rawValue ?? "",
                segment.chapterTitle ?? "",
                inlineStyles,
                blockStyles,
                segment.textContent,
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        let layoutPayload = [
            settings.fontFamily.rawValue,
            String(settings.fontScale),
            String(settings.lineHeightScale),
            String(settings.characterSpacingScale),
            String(settings.usesJustifiedText),
            String(settings.indentsParagraphFirstLine),
            String(settings.showsAuthorRepliesToOthers),
            settings.readingMode.rawValue,
            String(describing: layout.containerSize),
            String(describing: layout.safeAreaInsets),
            String(describing: layout.contentInsets),
            String(describing: layout.chromeInsets),
        ].joined(separator: "|")
        return NovelTextLayoutFingerprints(
            semantic: stableFingerprint(semanticPayload),
            text: stableFingerprint(viewportDocument.text),
            layout: stableFingerprint(layoutPayload)
        )
    }

    private static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func layoutMetrics(
        viewportIndex: NovelTextViewportIndex,
        layout: NovelReaderLayout
    ) -> NovelTextViewportLayoutMetrics {
        let surfaceMetrics = Dictionary(
            uniqueKeysWithValues: viewportIndex.surfaces.map { page in
                let textHeight = textHeightForViewportMetrics(
                    viewportSurface: page
                )
                let externalBlockHeight = CGFloat(page.externalBlocks.count) *
                    externalBlockPresentationHeight(layout: layout)
                let blockCount = (textHeight == nil ? 0 : 1) + page.externalBlocks.count
                let spacingHeight = CGFloat(max(blockCount - 1, 0)) * 14
                return (
                    page.surfaceOrdinal,
                    NovelTextViewportSurfaceLayoutMetrics(
                        surfaceOrdinal: page.surfaceOrdinal,
                        textHeight: textHeight,
                        externalBlockHeight: externalBlockHeight,
                        spacingHeight: spacingHeight
                    )
                )
            }
        )
        return NovelTextViewportLayoutMetrics(surfaceMetrics: surfaceMetrics)
    }

    private static func textHeightForViewportMetrics(
        viewportSurface: NovelTextViewportIndexSurface
    ) -> CGFloat? {
        if let frozenGeometry = viewportSurface.frozenGeometry {
            return frozenGeometry.contentHeight
        }
        return nil
    }

    private static func frozenExternalBlockFrame(layout: NovelReaderLayout) -> NovelTextViewportExternalBlockFrame {
        let contentWidth = max(layout.readableFrame.width, 1)
        let height = externalBlockPresentationHeight(layout: layout)
        return NovelTextViewportExternalBlockFrame(
            x: 0,
            y: 0,
            width: contentWidth,
            height: height
        )
    }

    private static func externalBlockPresentationHeight(layout: NovelReaderLayout) -> CGFloat {
        let readableHeight = max(layout.readableFrame.height, 160)
        guard layout.readingMode == .vertical else {
            let contentWidth = max(layout.readableFrame.width, 1)
            return min(max(contentWidth * 0.65, 160), readableHeight)
        }
        return readableHeight
    }

    private static func makeViewportContext(
        annotatedSegments: [NovelAnnotatedSegment],
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) -> NovelTextViewportContext {
        var composedText = ""
        var textRangesBySegment: [Int: NovelRenderedTextRange] = [:]
        var insertedSeparatorRanges: [NovelRenderedTextRange] = []
        var inlineTextStylesBySegment: [Int: [NovelInlineTextStyleRange]] = [:]
        var blockTextStyles: [NovelBlockTextStyleRange] = []
        var externalBlocks: [NovelTextViewportExternalBlock] = []
        var lastTextSegmentIndex: Int?

        for annotatedSegment in annotatedSegments {
            switch annotatedSegment.segment {
            case let .text(text, _):
                if !composedText.isEmpty {
                    let separatorStart = composedText.count
                    composedText.append("\n\n")
                    if let lastTextSegmentIndex {
                        insertedSeparatorRanges.append(
                            NovelRenderedTextRange(
                                segmentIndex: lastTextSegmentIndex,
                                startOffset: separatorStart,
                                endOffset: composedText.count
                            )
                        )
                    }
                }
                let startOffset = composedText.count
                composedText.append(text)
                textRangesBySegment[annotatedSegment.index] = NovelRenderedTextRange(
                    segmentIndex: annotatedSegment.index,
                    startOffset: startOffset,
                    endOffset: composedText.count
                )
                if let inlineTextStyles = annotatedSegment.semantics?.inlineTextStyles,
                   !inlineTextStyles.isEmpty {
                    inlineTextStylesBySegment[annotatedSegment.index] = inlineTextStyles
                }
                blockTextStyles.append(
                    contentsOf: (annotatedSegment.semantics?.blockTextStyles ?? []).compactMap { blockStyle in
                        guard blockStyle.range.length > 0,
                              blockStyle.range.upperBound <= text.count else {
                            return nil
                        }
                        return NovelBlockTextStyleRange(
                            style: blockStyle.style,
                            range: NovelCharacterRange(
                                location: startOffset + blockStyle.range.location,
                                length: blockStyle.range.length
                            )
                        )
                    }
                )
                lastTextSegmentIndex = annotatedSegment.index

            case let .image(url, _):
                externalBlocks.append(
                    NovelTextViewportExternalBlock(
                        chapterIdentity: annotatedSegment.semantics?.chapterIdentity,
                        imageSegmentIdentity: annotatedSegment.semantics?.textSegmentIdentity,
                        url: url,
                        chapterOrdinal: annotatedSegment.chapterOrdinal,
                        chapterTitle: annotatedSegment.chapterTitle,
                        chapterCommentTarget: chapterCommentTarget(for: annotatedSegment, document: document)
                    )
                )
            }
        }

        return NovelTextViewportContext(
            identity: NovelTextViewportIdentity(
                threadID: document.threadID,
                documentView: document.view,
                maxView: document.maxView,
                fetchedAt: document.fetchedAt,
                appearance: settings,
                layout: layout
            ),
            document: NovelTextViewportDocument(
                text: composedText,
                textRangesBySegment: textRangesBySegment,
                insertedSeparatorRanges: insertedSeparatorRanges,
                inlineTextStylesBySegment: inlineTextStylesBySegment,
                blockTextStyles: blockTextStyles
            ),
            externalBlocks: externalBlocks,
            diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
        )
    }

    private static func validateOffsetMap(
        annotatedSegments: [NovelAnnotatedSegment],
        viewportDocument: NovelTextViewportDocument
    ) throws {
        let textBySegment = Dictionary(uniqueKeysWithValues: annotatedSegments.compactMap {
            annotatedSegment -> (Int, String)? in
            guard case let .text(text, _) = annotatedSegment.segment else { return nil }
            return (annotatedSegment.index, text)
        })
        guard viewportDocument.validateOffsetMap(expectedTextBySegment: textBySegment) else {
            throw NovelTextLayoutFailure.offsetMapping
        }
    }

    private static func segmentRanges(
        for surfaceRange: NovelTextViewportDocumentSurfaceRange,
        viewportDocument: NovelTextViewportDocument
    ) -> [NovelRenderedTextRange] {
        viewportDocument.surfaceRanges(for: surfaceRange)
    }

    private static func splitTextRanges(
        _ ranges: [NovelRenderedTextRange],
        aroundImageSegmentIndexes imageSegmentIndexes: Set<Int>,
        annotatedSegmentByIndex: [Int: NovelAnnotatedSegment],
        document: NovelReaderProjection
    ) -> [[NovelRenderedTextRange]] {
        guard !ranges.isEmpty else { return [] }

        var groups: [[NovelRenderedTextRange]] = []
        var currentGroup: [NovelRenderedTextRange] = []
        var previousSegmentIndex: Int?

        for range in ranges {
            if let previousSegmentIndex,
               !currentGroup.isEmpty,
               shouldStartNewTextRangeGroup(
                   previousSegmentIndex: previousSegmentIndex,
                   nextSegmentIndex: range.segmentIndex,
                   imageSegmentIndexes: imageSegmentIndexes,
                   annotatedSegmentByIndex: annotatedSegmentByIndex,
                   document: document
               ) {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(range)
            previousSegmentIndex = range.segmentIndex
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        return groups
    }

    private static func shouldStartNewTextRangeGroup(
        previousSegmentIndex: Int,
        nextSegmentIndex: Int,
        imageSegmentIndexes: Set<Int>,
        annotatedSegmentByIndex: [Int: NovelAnnotatedSegment],
        document: NovelReaderProjection
    ) -> Bool {
        if imageSegmentIndexes.contains(where: { imageSegmentIndex in
            imageSegmentIndex > previousSegmentIndex && imageSegmentIndex < nextSegmentIndex
        }) {
            return true
        }
        let previousSegment = annotatedSegmentByIndex[previousSegmentIndex]
        let nextSegment = annotatedSegmentByIndex[nextSegmentIndex]
        return previousSegment?.chapterOrdinal != nextSegment?.chapterOrdinal ||
            previousSegment.flatMap { chapterCommentTarget(for: $0, document: document) } !=
            nextSegment.flatMap { chapterCommentTarget(for: $0, document: document) }
    }

    private static func text(
        for range: NovelRenderedTextRange,
        annotatedTextBySegment: [Int: String]
    ) -> String? {
        guard let text = annotatedTextBySegment[range.segmentIndex] else { return nil }
        let startOffset = min(max(range.startOffset, 0), text.count)
        let endOffset = min(max(range.endOffset, startOffset), text.count)
        guard endOffset > startOffset,
              let startIndex = text.index(text.startIndex, offsetBy: startOffset, limitedBy: text.endIndex),
              let endIndex = text.index(text.startIndex, offsetBy: endOffset, limitedBy: text.endIndex) else {
            return nil
        }
        return String(text[startIndex..<endIndex])
    }

    private static func startsAtParagraphBoundary(
        viewportContext: NovelTextViewportContext,
        viewportSurface: NovelTextViewportIndexSurface
    ) -> Bool {
        viewportContext.document.startsAtParagraphBoundary(surface: viewportSurface)
    }

    private static func annotatedSegments(
        from document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings
    ) -> [NovelAnnotatedSegment] {
        var results: [NovelAnnotatedSegment] = []
        var currentChapterIdentity: NovelChapterIdentity?
        var currentChapterTitle: String?
        var currentChapterOrdinal: Int?
        var nextChapterOrdinal = 0

        let segmentInputs = zip(
            document.segments.indices,
            zip(document.segments, zip(document.segmentSemantics, document.segmentSources))
        )
        for (index, input) in segmentInputs {
            let (segment, semanticAndSource) = input
            let (semantics, source) = semanticAndSource
            if source?.isAuthorReplyToOther == true, !settings.showsAuthorRepliesToOthers {
                continue
            }
            guard let transformed = transformedSegment(
                from: segment,
                semantics: semantics,
                settings: settings
            ) else {
                continue
            }
            let transformedSegment = transformed.segment
            let transformedSemantics = transformed.semantics
            let explicitChapterTitle = segment.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let semanticChapterIdentity: NovelChapterIdentity? = if case .image = segment,
                transformedSemantics?.textSegmentIdentity == nil,
                let explicitChapterTitle,
                !explicitChapterTitle.isEmpty,
                explicitChapterTitle == currentChapterTitle,
                let currentChapterIdentity {
                currentChapterIdentity
            } else {
                transformedSemantics?.chapterIdentity
            }

            if let semanticChapterIdentity, !semanticChapterIdentity.rawValue.isEmpty {
                if currentChapterIdentity != semanticChapterIdentity {
                    currentChapterIdentity = semanticChapterIdentity
                    currentChapterOrdinal = nextChapterOrdinal
                    nextChapterOrdinal += 1
                }
                if let explicitChapterTitle, !explicitChapterTitle.isEmpty {
                    currentChapterTitle = explicitChapterTitle
                }
            } else if let explicitChapterTitle, !explicitChapterTitle.isEmpty {
                if currentChapterTitle != explicitChapterTitle {
                    currentChapterIdentity = nil
                    currentChapterTitle = explicitChapterTitle
                    currentChapterOrdinal = nextChapterOrdinal
                    nextChapterOrdinal += 1
                }
            }

            results.append(
                NovelAnnotatedSegment(
                    index: index,
                    segment: transformedSegment,
                    semantics: transformedSemantics,
                    source: source,
                    chapterOrdinal: currentChapterOrdinal,
                    chapterTitle: currentChapterTitle
                )
            )
        }

        return results
    }

    private static func transformedSegment(
        from segment: NovelReaderSegment,
        semantics: NovelReaderSegmentSemantics?,
        settings: NovelReaderAppearanceSettings
    ) -> (segment: NovelReaderSegment, semantics: NovelReaderSegmentSemantics?)? {
        switch segment {
        case let .text(text, chapterTitle):
            let transformed = transformTextAndStyles(
                text: text,
                inlineTextStyles: semantics?.inlineTextStyles ?? [],
                blockTextStyles: semantics?.blockTextStyles ?? [],
                mode: settings.translationMode
            )
            var transformedSemantics = semantics
            transformedSemantics?.inlineTextStyles = transformed.inlineTextStyles
            transformedSemantics?.blockTextStyles = transformed.blockTextStyles
            return (.text(transformed.text, chapterTitle: chapterTitle), transformedSemantics)
        case let .image(url, chapterTitle):
            return settings.loadsInlineImages ? (.image(url, chapterTitle: chapterTitle), semantics) : nil
        }
    }

    private static func transformTextAndStyles(
        text: String,
        inlineTextStyles: [NovelInlineTextStyleRange],
        blockTextStyles: [NovelBlockTextStyleRange],
        mode: ReaderTranslationMode
    ) -> (
        text: String,
        inlineTextStyles: [NovelInlineTextStyleRange],
        blockTextStyles: [NovelBlockTextStyleRange]
    ) {
        guard mode != .none else {
            return (
                NovelTextTransformer.transform(text, mode: mode),
                inlineTextStyles,
                blockTextStyles
            )
        }

        guard !inlineTextStyles.isEmpty || !blockTextStyles.isEmpty else {
            return (NovelTextTransformer.transform(text, mode: mode), inlineTextStyles, blockTextStyles)
        }

        let boundaries = styleBoundaries(
            textCount: text.count,
            inlineTextStyles: inlineTextStyles,
            blockTextStyles: blockTextStyles
        )
        var output = ""
        var transformedOffsets: [Int: Int] = [0: 0]

        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            transformedOffsets[start] = output.count
            output += NovelTextTransformer.transform(
                substring(in: text, range: start ..< end),
                mode: mode
            )
            transformedOffsets[end] = output.count
        }

        return (
            output,
            inlineTextStyles.compactMap { transformedInlineStyle($0, transformedOffsets: transformedOffsets) },
            blockTextStyles.compactMap { transformedBlockStyle($0, transformedOffsets: transformedOffsets) }
        )
    }

    private static func styleBoundaries(
        textCount: Int,
        inlineTextStyles: [NovelInlineTextStyleRange],
        blockTextStyles: [NovelBlockTextStyleRange]
    ) -> [Int] {
        var boundaries = Set([0, textCount])
        for range in inlineTextStyles.map(\.range) + blockTextStyles.map(\.range) {
            let start = min(max(range.location, 0), textCount)
            let end = min(max(range.upperBound, start), textCount)
            boundaries.insert(start)
            boundaries.insert(end)
        }
        return boundaries.sorted()
    }

    private static func transformedInlineStyle(
        _ style: NovelInlineTextStyleRange,
        transformedOffsets: [Int: Int]
    ) -> NovelInlineTextStyleRange? {
        guard let transformedStart = transformedOffsets[style.range.location],
              let transformedEnd = transformedOffsets[style.range.upperBound],
              transformedEnd > transformedStart else {
            return nil
        }
        return NovelInlineTextStyleRange(
            style: style.style,
            range: NovelCharacterRange(
                location: transformedStart,
                length: transformedEnd - transformedStart
            )
        )
    }

    private static func transformedBlockStyle(
        _ style: NovelBlockTextStyleRange,
        transformedOffsets: [Int: Int]
    ) -> NovelBlockTextStyleRange? {
        guard let transformedStart = transformedOffsets[style.range.location],
              let transformedEnd = transformedOffsets[style.range.upperBound],
              transformedEnd > transformedStart else {
            return nil
        }
        return NovelBlockTextStyleRange(
            style: style.style,
            range: NovelCharacterRange(
                location: transformedStart,
                length: transformedEnd - transformedStart
            )
        )
    }

    private static func substring(in text: String, range: Range<Int>) -> String {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        return String(text[lower..<upper])
    }

    private static func chapterCommentTarget(
        for annotatedSegment: NovelAnnotatedSegment,
        document: NovelReaderProjection
    ) -> ReaderChapterCommentTarget? {
        guard let ownerPostID = annotatedSegment.source?.ownerPostID,
              !ownerPostID.isEmpty else {
            return nil
        }
        return ReaderChapterCommentTarget(
            threadID: document.threadID,
            view: document.view,
            ownerPostID: ownerPostID,
            title: annotatedSegment.chapterTitle,
            authorID: document.resolvedAuthorID
        )
    }

}

package struct NovelTextViewportDocumentSurfaceRange: Hashable, Sendable {
    package let startOffset: Int
    package let endOffset: Int
    package let frozenGeometry: NovelTextViewportFrozenGeometry?

    package var isEmpty: Bool {
        endOffset <= startOffset
    }

    package init(
        startOffset: Int,
        endOffset: Int,
        frozenGeometry: NovelTextViewportFrozenGeometry? = nil
    ) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.frozenGeometry = frozenGeometry
    }
}

package struct NovelAnnotatedSegment: Sendable {
    package let index: Int
    package let segment: NovelReaderSegment
    package let semantics: NovelReaderSegmentSemantics?
    package let source: NovelReaderSegmentSource?
    package let chapterOrdinal: Int?
    package let chapterTitle: String?

    package var textContent: String {
        guard case let .text(text, _) = segment else { return "" }
        return text
    }
}

private struct NovelViewportSurfaceDraft {
    let orderSegmentIndex: Int
    let ordinal: Int
    let kind: NovelViewportSurfaceDraftKind
}

private enum NovelViewportSurfaceDraftKind {
    case text([NovelRenderedTextRange], frozenGeometry: NovelTextViewportFrozenGeometry?)
    case image(url: URL, chapterTitle: String?, externalBlock: NovelTextViewportExternalBlock)
}
