import Foundation
import UIKit
import YamiboXCore

/// The live TextKit 2 object graph for one committed runtime generation.
/// Owns fragment geometry queries, viewport sampling, selection geometry, and
/// committed drawing; Core's `NovelTextViewportRuntimeOwner` forwards to it
/// after generation and surface-identity validation.
final class NovelTextKitViewportGraph: NovelTextViewportRuntimeGraph {
    private let result: NovelTextLayoutResult
    private let document: NovelReaderProjection
    private let settings: NovelReaderAppearanceSettings
    private let layout: NovelReaderLayout
    private let textContentStorage: NSTextContentStorage
    private let textLayoutManager: NSTextLayoutManager
    private let textContainer: NSTextContainer
    private let textViewportLayoutController: NSTextViewportLayoutController
    private let textViewportLayoutDelegate: NovelTextViewportLayoutDelegate
    private let pagesByOrdinal: [Int: NovelTextViewportIndexSurface]
    private let quoteStyles: [NovelRuntimeBlockTextStyle]
    private let quotePrefixMaxEnd: [Int]

    init(
        result: NovelTextLayoutResult,
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        textContentStorage: NSTextContentStorage,
        textLayoutManager: NSTextLayoutManager,
        textContainer: NSTextContainer,
        textViewportLayoutController: NSTextViewportLayoutController,
        textViewportLayoutDelegate: NovelTextViewportLayoutDelegate
    ) {
        self.result = result
        self.document = document
        self.settings = settings
        self.layout = layout
        self.textContentStorage = textContentStorage
        self.textLayoutManager = textLayoutManager
        self.textContainer = textContainer
        self.textViewportLayoutController = textViewportLayoutController
        self.textViewportLayoutDelegate = textViewportLayoutDelegate
        pagesByOrdinal = Dictionary(
            uniqueKeysWithValues: result.viewportIndex.surfaces.map { ($0.surfaceOrdinal, $0) }
        )
        let sortedQuoteStyles = result.viewportContext.document.blockTextStyles
            .filter { $0.style == .quote }
            .sorted { $0.range.location < $1.range.location }
        quoteStyles = sortedQuoteStyles
        var maxEnd = 0
        quotePrefixMaxEnd = sortedQuoteStyles.map { style in
            maxEnd = max(maxEnd, NSMaxRange(style.range))
            return maxEnd
        }
    }

    func viewportSample(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelTextViewportSample? {
        let surfaceOrdinal = surfaceIdentity.ordinal
        guard let page = page(forSurfaceOrdinal: surfaceOrdinal),
              let documentOffset = unclampedDocumentOffset(page: page, referencePoint: referencePoint) else {
            return nil
        }

        guard let sample = result.viewportContext.document.sample(
            containingDocumentOffset: documentOffset,
            surfaceIdentity: surfaceIdentity,
            documentView: page.documentView,
            in: document
        ) else {
            return page.nearestTextSample(
                toDocumentOffset: documentOffset,
                surfaceIdentity: NovelReaderSurfaceIdentity(
                    generation: surfaceIdentity.generation,
                    ordinal: page.surfaceOrdinal
                ),
                viewportDocument: result.viewportContext.document,
                sourceDocument: document
            )
        }
        return sample
    }

    func referenceY(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        position: NovelResumePoint
    ) -> CGFloat? {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              let documentOffset = result.viewportContext.document.documentOffset(for: position, in: document),
              let surfaceOriginY = surfaceOriginY(page: page),
              let location = textContentStorage.location(
                  textContentStorage.documentRange.location,
                  offsetBy: documentOffset.rawValue
              ),
              let fragment = textLayoutManager.textLayoutFragment(for: location),
              let lineFragment = fragment.textLineFragment(for: location, isUpstreamAffinity: true) else {
            return nil
        }
        if let frozenGeometry = page.frozenGeometry,
           (documentOffset < frozenGeometry.documentStartOffset || documentOffset >= frozenGeometry.documentEndOffset) {
            return nil
        }
        return fragment.layoutFragmentFrame.minY + lineFragment.typographicBounds.midY - surfaceOriginY
    }

    func documentUTF16Offset(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelDocumentUTF16Offset? {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              !page.ranges.isEmpty,
              let pageDocumentRange = documentRange(for: page),
              let offset = unclampedDocumentOffset(page: page, referencePoint: referencePoint) else {
            return nil
        }
        return min(max(offset, pageDocumentRange.lowerBound), pageDocumentRange.upperBound)
    }

    /// Both viewport sampling and selection use the same coordinate conversion;
    /// their nearest-sample fallback and page-range clipping remain independent.
    private func unclampedDocumentOffset(
        page: NovelTextViewportIndexSurface,
        referencePoint: CGPoint
    ) -> NovelDocumentUTF16Offset? {
        guard let surfaceOriginY = surfaceOriginY(page: page),
              let fragment = closestLayoutFragment(
                  to: CGPoint(x: referencePoint.x, y: surfaceOriginY + referencePoint.y),
                  in: page
              ) else {
            return nil
        }

        let documentStart = textContentStorage.documentRange.location
        let fragmentStart = textContentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
        guard fragmentStart != NSNotFound else { return nil }
        let fragmentPoint = CGPoint(
            x: referencePoint.x - fragment.layoutFragmentFrame.minX,
            y: surfaceOriginY + referencePoint.y - fragment.layoutFragmentFrame.minY
        )
        let lineOffset: Int
        if let lineFragment = fragment.textLineFragment(
            forVerticalOffset: fragmentPoint.y,
            requiresExactMatch: false
        ) {
            let linePoint = CGPoint(
                x: fragmentPoint.x - lineFragment.typographicBounds.minX,
                y: fragmentPoint.y - lineFragment.typographicBounds.minY
            )
            lineOffset = min(
                max(lineFragment.characterIndex(for: linePoint), lineFragment.characterRange.location),
                lineFragment.characterRange.location + lineFragment.characterRange.length
            )
        } else {
            lineOffset = 0
        }
        let utf16Offset = fragmentStart + lineOffset
        return NovelDocumentUTF16Offset(result.viewportContext.document.coordinates.alignedOffset(utf16Offset))
    }

    func selectionRects(
        for selectionRange: NovelTextSelectionRange,
        surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> [CGRect] {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              !page.ranges.isEmpty,
              let pageDocumentRange = documentRange(for: page),
              let intersection = intersection(selectionRange.range, pageDocumentRange),
              let utf16Range = utf16Range(for: intersection),
              let start = textContentStorage.location(textContentStorage.documentRange.location, offsetBy: utf16Range.location),
              let end = textContentStorage.location(start, offsetBy: utf16Range.length),
              let textRange = NSTextRange(location: start, end: end),
              let surfaceOriginY = surfaceOriginY(page: page) else {
            return []
        }

        let documentClipRange = page.frozenGeometry.map {
            CGRect(
                x: 0,
                y: $0.documentClipMinY,
                width: max(layout.readableFrame.width, 1),
                height: max($0.documentClipMaxY - $0.documentClipMinY, 1)
            )
        }
        var rects: [CGRect] = []
        textLayoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: []
        ) { _, rect, _, _ in
            var clippedRect = rect
            if let documentClipRange {
                clippedRect = clippedRect.intersection(documentClipRange)
            }
            guard !clippedRect.isNull,
                  clippedRect.width.isFinite,
                  clippedRect.height.isFinite,
                  clippedRect.width > 0,
                  clippedRect.height > 0 else {
                return true
            }
            rects.append(
                CGRect(
                    x: clippedRect.minX,
                    y: clippedRect.minY - surfaceOriginY,
                    width: clippedRect.width,
                    height: clippedRect.height
                )
            )
            return true
        }
        return rects
    }

    func drawBlockBackgrounds(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    ) {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              let surfaceOriginY = surfaceOriginY(page: page),
              let pageDocumentRange = documentRange(for: page) else {
            return
        }

        let documentClipRange = page.frozenGeometry.map {
            CGRect(
                x: 0,
                y: $0.documentClipMinY,
                width: max(layout.readableFrame.width, 1),
                height: max($0.documentClipMaxY - $0.documentClipMinY, 1)
            )
        }
        let clipMaxY = page.frozenGeometry.map {
            surfaceOriginY + $0.contentHeight
        } ?? surfaceOriginY + bounds.height
        let pageClipRect = NovelTextViewportDrawingGeometry.clipRect(
            bounds: bounds,
            surfaceOriginY: surfaceOriginY,
            documentClipMaxY: clipMaxY
        )

        context.saveGState()
        context.clip(to: pageClipRect)
        context.translateBy(x: bounds.minX, y: bounds.minY - surfaceOriginY)
        if settings.forumFormat.quote {
            context.setFillColor(NovelForumColorRenderer.quoteBackground(for: settings).cgColor)
            for blockStyle in visibleQuoteStyles(in: pageDocumentRange) {
                let quoteRange = NovelDocumentUTF16Offset(blockStyle.range.location)..<NovelDocumentUTF16Offset(NSMaxRange(blockStyle.range))
                guard let visibleQuoteRange = intersection(quoteRange, pageDocumentRange),
                      let utf16Range = utf16Range(for: visibleQuoteRange),
                      let start = textContentStorage.location(
                        textContentStorage.documentRange.location,
                        offsetBy: utf16Range.location
                      ),
                      let end = textContentStorage.location(start, offsetBy: utf16Range.length),
                      let textRange = NSTextRange(location: start, end: end) else {
                    continue
                }

                var backgroundRect: CGRect?
                textLayoutManager.enumerateTextSegments(
                    in: textRange,
                    type: .standard,
                    options: []
                ) { _, rect, _, _ in
                    var clippedRect = rect
                    if let documentClipRange {
                        clippedRect = clippedRect.intersection(documentClipRange)
                    }
                    guard !clippedRect.isNull,
                          clippedRect.width.isFinite,
                          clippedRect.height.isFinite,
                          clippedRect.width > 0,
                          clippedRect.height > 0 else {
                        return true
                    }
                    let paddedRect = clippedRect.insetBy(dx: -10, dy: -6)
                    backgroundRect = backgroundRect.map { $0.union(paddedRect) } ?? paddedRect
                    return true
                }

                guard let backgroundRect,
                      backgroundRect.width > 0,
                      backgroundRect.height > 0 else {
                    continue
                }
                let path = UIBezierPath(
                    roundedRect: backgroundRect,
                    cornerRadius: min(8, max(backgroundRect.height / 2, 0))
                ).cgPath
                context.addPath(path)
                context.fillPath()
            }
        }
        drawAuthoredBackgrounds(pageDocumentRange: pageDocumentRange,
                                documentClipRange: documentClipRange, in: context)
        context.restoreGState()
    }

    private func drawAuthoredBackgrounds(
        pageDocumentRange: Range<NovelDocumentUTF16Offset>,
        documentClipRange: CGRect?,
        in context: CGContext
    ) {
        guard settings.forumFormat.backgroundColor,
              let attributed = textContentStorage.textStorage,
              pageDocumentRange.upperBound.rawValue <= attributed.length else { return }
        let range = NSRange(location: pageDocumentRange.lowerBound.rawValue,
                            length: pageDocumentRange.upperBound - pageDocumentRange.lowerBound)
        attributed.enumerateAttribute(.novelAuthoredBackground, in: range) { value, run, _ in
            guard let color = value as? UIColor,
                  let start = textContentStorage.location(textContentStorage.documentRange.location,
                                                          offsetBy: run.location),
                  let end = textContentStorage.location(start, offsetBy: run.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            context.setFillColor(color.cgColor)
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                let clipped = documentClipRange.map { rect.intersection($0) } ?? rect
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return true }
                let highlight = clipped.insetBy(dx: -2, dy: -1)
                context.addPath(UIBezierPath(roundedRect: highlight, cornerRadius: 3).cgPath)
                context.fillPath()
                return true
            }
        }
    }

    @discardableResult
    func draw(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    ) -> Bool {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              let surfaceOriginY = surfaceOriginY(page: page),
              let pageLocation = pageStartLocation(page: page) else {
            return false
        }
        let visibleDocumentRange = page.frozenGeometry.map {
            $0.documentStartOffset.rawValue..<$0.documentEndOffset.rawValue
        }
        let clipMaxY = page.frozenGeometry.map {
            surfaceOriginY + $0.contentHeight
        } ?? surfaceOriginY + bounds.height
        let pageClipRect = NovelTextViewportDrawingGeometry.clipRect(
            bounds: bounds,
            surfaceOriginY: surfaceOriginY,
            documentClipMaxY: clipMaxY
        )
        context.saveGState()
        context.clip(to: pageClipRect)
        context.translateBy(x: bounds.minX, y: bounds.minY - surfaceOriginY)
        let documentStart = textContentStorage.documentRange.location
        textLayoutManager.enumerateTextLayoutFragments(
            from: pageLocation,
            options: []
        ) { fragment in
            let fragmentStart = textContentStorage.offset(
                from: documentStart,
                to: fragment.rangeInElement.location
            )
            guard fragmentStart != NSNotFound else { return false }
            guard fragment.layoutFragmentFrame.minY < clipMaxY else {
                return false
            }
            guard fragment.layoutFragmentFrame.maxY >= surfaceOriginY else {
                return true
            }
            if let visibleDocumentRange {
                var shouldContinue = true
                var lineClipRects: [CGRect] = []
                for lineFragment in fragment.textLineFragments {
                    let lineStart = fragmentStart + lineFragment.characterRange.location
                    let lineEnd = lineStart + lineFragment.characterRange.length
                    if lineStart >= visibleDocumentRange.upperBound {
                        shouldContinue = false
                        break
                    }
                    guard NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
                        fragmentStart: lineStart,
                        fragmentEnd: lineEnd,
                        documentRange: visibleDocumentRange
                    ) else {
                        continue
                    }
                    let lineBounds = lineFragment.typographicBounds
                    let lineRect = CGRect(
                        x: fragment.layoutFragmentFrame.minX + lineBounds.minX,
                        y: fragment.layoutFragmentFrame.minY + lineBounds.minY,
                        width: max(lineBounds.width, 1),
                        height: max(lineBounds.height, 1)
                    ).insetBy(dx: 0, dy: -1)
                    lineClipRects.append(lineRect)
                }
                if !lineClipRects.isEmpty {
                    // A layout fragment draws its entire paragraph. Drawing it
                    // once per visible line repeats that work during scrolling;
                    // clip to the same line rectangles in a single draw instead.
                    context.saveGState()
                    context.clip(to: lineClipRects)
                    fragment.draw(
                        at: fragment.layoutFragmentFrame.origin,
                        in: context
                    )
                    context.restoreGState()
                }
                return shouldContinue
            }
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
        drawRuby(pageDocumentRange: page.frozenGeometry.map {
            $0.documentStartOffset..<$0.documentEndOffset
        } ?? documentRange(for: page))
        context.restoreGState()
        return true
    }

    private func drawRuby(pageDocumentRange: Range<NovelDocumentUTF16Offset>?) {
        guard settings.forumFormat.ruby, let pageDocumentRange,
              let attributed = textContentStorage.textStorage,
              pageDocumentRange.upperBound.rawValue <= attributed.length else { return }
        let range = NSRange(location: pageDocumentRange.lowerBound.rawValue,
                            length: pageDocumentRange.upperBound - pageDocumentRange.lowerBound)
        let documentStart = textContentStorage.documentRange.location
        attributed.enumerateAttribute(.novelRuby, in: range) { value, run, _ in
            guard let annotation = value as? NovelRubyAnnotation,
                  let start = textContentStorage.location(documentStart, offsetBy: run.location),
                  let end = textContentStorage.location(start, offsetBy: run.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            var original = NSRange()
            _ = attributed.attribute(.novelRuby, at: run.location, effectiveRange: &original)
            let baseCoordinates = NovelTextCoordinateIndex(
                (attributed.string as NSString).substring(with: original)
            )
            let fontSize = NovelAttributedTextFactory.defaultBaseFontSize * settings.fontScale * 0.5
            let font = settings.readerFont(size: fontSize, weight: .light)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: (attributed.attribute(.foregroundColor, at: run.location,
                                                       effectiveRange: nil) as? UIColor)
                    ?? readerThemeTextUIColor(for: settings.backgroundStyle),
                .paragraphStyle: paragraph,
            ]
            let rubyCharacters = Array(annotation.text)
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, rect, _, _ in
                guard let segment, rect.width > 0, rect.height > 0 else { return true }
                let startOffset = textContentStorage.offset(from: documentStart, to: segment.location)
                let endOffset = textContentStorage.offset(from: documentStart, to: segment.endLocation)
                guard startOffset != NSNotFound, endOffset != NSNotFound,
                      baseCoordinates.characterCount > 0 else { return true }
                let firstBase = baseCoordinates.characterOffset(
                    forUTF16Offset: startOffset - original.location
                )
                let lastBase = baseCoordinates.characterOffset(
                    forUTF16Offset: endOffset - original.location, roundingUp: true
                )
                let first = min((firstBase * rubyCharacters.count + baseCoordinates.characterCount - 1)
                    / baseCoordinates.characterCount, rubyCharacters.count)
                let last = min((lastBase * rubyCharacters.count + baseCoordinates.characterCount - 1)
                    / baseCoordinates.characterCount, rubyCharacters.count)
                guard last > first else { return true }
                let label = String(rubyCharacters[first..<last])
                var attributes = baseAttributes
                let availableWidth = max(rect.width, 1)
                let naturalWidth = (label as NSString).size(withAttributes: attributes).width
                if naturalWidth > availableWidth {
                    attributes[.font] = settings.readerFont(
                        size: fontSize * Double(availableWidth / naturalWidth), weight: .light
                    )
                }
                let height = ceil((attributes[.font] as? UIFont ?? font).lineHeight)
                let lineFragment = textLayoutManager.textLayoutFragment(for: segment.location)
                let lineTop = lineFragment.flatMap { fragment in
                    fragment.textLineFragment(for: segment.location, isUpstreamAffinity: false)
                        .map { line in fragment.layoutFragmentFrame.minY + line.typographicBounds.minY }
                } ?? rect.minY
                let labelRect = CGRect(x: rect.minX, y: lineTop - height - 2,
                                       width: availableWidth, height: height)
                (label as NSString).draw(in: labelRect, withAttributes: attributes)
                return true
            }
        }
    }

    private func page(forSurfaceOrdinal surfaceOrdinal: Int) -> NovelTextViewportIndexSurface? {
        pagesByOrdinal[surfaceOrdinal]
    }

    private func visibleQuoteStyles(in documentRange: Range<NovelDocumentUTF16Offset>) -> ArraySlice<NovelRuntimeBlockTextStyle> {
        var low = 0
        var high = quotePrefixMaxEnd.count
        while low < high {
            let mid = (low + high) / 2
            if quotePrefixMaxEnd[mid] <= documentRange.lowerBound.rawValue {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let start = low
        while low < quoteStyles.count, quoteStyles[low].range.location < documentRange.upperBound.rawValue {
            low += 1
        }
        return quoteStyles[start..<low]
    }

    private func surfaceOriginY(page: NovelTextViewportIndexSurface) -> CGFloat? {
        if let frozenGeometry = page.frozenGeometry {
            return frozenGeometry.pageLocalOriginY
        }
        guard let firstRange = page.ranges.first,
              let documentOffset = result.viewportContext.document.documentOffset(forSurfaceRange: firstRange),
              let pageLocation = textContentStorage.location(
                textContentStorage.documentRange.location,
                offsetBy: documentOffset.rawValue
              ),
              let firstFragment = textLayoutManager.textLayoutFragment(for: pageLocation) else {
            return nil
        }
        guard let firstLineFragment = firstFragment.textLineFragment(
            for: pageLocation,
            isUpstreamAffinity: false
        ) else {
            return firstFragment.layoutFragmentFrame.minY
        }
        return firstFragment.layoutFragmentFrame.minY + firstLineFragment.typographicBounds.minY
    }

    private func closestLayoutFragment(
        to point: CGPoint,
        in page: NovelTextViewportIndexSurface
    ) -> NSTextLayoutFragment? {
        if let fragment = textLayoutManager.textLayoutFragment(for: point) {
            return fragment
        }
        guard let start = pageStartLocation(page: page),
              let pageRange = documentRange(for: page) else { return nil }
        var best: (distance: CGFloat, fragment: NSTextLayoutFragment)?
        textLayoutManager.enumerateTextLayoutFragments(
            from: start,
            options: []
        ) { fragment in
            let fragmentStart = textContentStorage.offset(
                from: textContentStorage.documentRange.location,
                to: fragment.rangeInElement.location
            )
            guard fragmentStart != NSNotFound,
                  fragmentStart < pageRange.upperBound.rawValue else { return false }
            let frame = fragment.layoutFragmentFrame
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance {
                best = (distance, fragment)
            }
            return true
        }
        return best?.fragment
    }

    private func pageStartLocation(page: NovelTextViewportIndexSurface) -> NSTextLocation? {
        if let frozenGeometry = page.frozenGeometry {
            return textContentStorage.location(
                textContentStorage.documentRange.location,
                offsetBy: frozenGeometry.documentStartOffset.rawValue
            )
        }
        guard let firstRange = page.ranges.first,
              let documentOffset = result.viewportContext.document.documentOffset(forSurfaceRange: firstRange) else {
            return nil
        }
        return textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: documentOffset.rawValue
        )
    }

    private func documentRange(for page: NovelTextViewportIndexSurface) -> Range<NovelDocumentUTF16Offset>? {
        if let frozenGeometry = page.frozenGeometry,
           frozenGeometry.documentEndOffset > frozenGeometry.documentStartOffset {
            return frozenGeometry.documentStartOffset..<frozenGeometry.documentEndOffset
        }
        let ranges = page.ranges.compactMap {
            result.viewportContext.document.documentOffsets(forSurfaceRange: $0)
        }
        guard let lowerBound = ranges.map(\.lowerBound).min(),
              let upperBound = ranges.map(\.upperBound).max(),
              upperBound > lowerBound else {
            return nil
        }
        return lowerBound..<upperBound
    }

    private func intersection(_ lhs: Range<NovelDocumentUTF16Offset>, _ rhs: Range<NovelDocumentUTF16Offset>) -> Range<NovelDocumentUTF16Offset>? {
        let lowerBound = max(lhs.lowerBound, rhs.lowerBound)
        let upperBound = min(lhs.upperBound, rhs.upperBound)
        guard upperBound > lowerBound else { return nil }
        return lowerBound..<upperBound
    }

    private func utf16Range(for range: Range<NovelDocumentUTF16Offset>) -> NSRange? {
        let coordinates = result.viewportContext.document.coordinates
        guard range.lowerBound.rawValue >= 0, range.upperBound.rawValue <= coordinates.utf16Count else { return nil }
        let aligned = coordinates.alignedRange(range.lowerBound.rawValue..<range.upperBound.rawValue)
        return NSRange(location: aligned.lowerBound, length: aligned.count)
    }

}
