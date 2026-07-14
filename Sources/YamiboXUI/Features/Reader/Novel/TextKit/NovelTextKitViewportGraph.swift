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
    }

    func viewportSample(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelTextViewportSample? {
        let surfaceOrdinal = surfaceIdentity.ordinal
        guard let page = page(forSurfaceOrdinal: surfaceOrdinal),
              let surfaceOriginY = surfaceOriginY(page: page),
              let fragment = closestLayoutFragment(
                  to: CGPoint(x: referencePoint.x, y: surfaceOriginY + referencePoint.y)
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
        let documentOffset = fragmentStart + lineOffset
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
                  offsetBy: documentOffset
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

    func characterDocumentOffset(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> Int? {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              !page.ranges.isEmpty,
              let pageCharacterRange = characterRange(for: page),
              let surfaceOriginY = surfaceOriginY(page: page),
              let fragment = closestLayoutFragment(
                  to: CGPoint(x: referencePoint.x, y: surfaceOriginY + referencePoint.y)
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
        guard let characterOffset = characterOffset(
            in: result.viewportContext.document.text,
            fromUTF16Offset: utf16Offset
        ) else {
            return nil
        }
        return min(max(characterOffset, pageCharacterRange.lowerBound), pageCharacterRange.upperBound)
    }

    func selectionRects(
        for selectionRange: NovelTextSelectionRange,
        surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> [CGRect] {
        guard let page = page(forSurfaceOrdinal: surfaceIdentity.ordinal),
              !page.ranges.isEmpty,
              let pageCharacterRange = characterRange(for: page),
              let intersection = intersection(selectionRange.range, pageCharacterRange),
              let utf16Range = utf16Range(in: result.viewportContext.document.text, characterRange: intersection),
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
              let pageCharacterRange = characterRange(for: page) else {
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
        context.setFillColor(quoteBlockBackgroundColor().cgColor)
        for blockStyle in result.viewportContext.document.blockTextStyles where blockStyle.style == .quote {
            let quoteRange = blockStyle.range.location..<blockStyle.range.upperBound
            guard let visibleQuoteRange = intersection(quoteRange, pageCharacterRange),
                  let utf16Range = utf16Range(in: result.viewportContext.document.text, characterRange: visibleQuoteRange),
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
        context.restoreGState()
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
        let documentRange = page.frozenGeometry.map {
            $0.documentStartOffset..<$0.documentEndOffset
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
            if let documentRange {
                var shouldContinue = true
                for lineFragment in fragment.textLineFragments {
                    let lineStart = fragmentStart + lineFragment.characterRange.location
                    let lineEnd = lineStart + lineFragment.characterRange.length
                    if lineStart >= documentRange.upperBound {
                        shouldContinue = false
                        break
                    }
                    guard NovelTextViewportDrawingGeometry.fragmentStartsInDocumentRange(
                        fragmentStart: lineStart,
                        fragmentEnd: lineEnd,
                        documentRange: documentRange
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
                    context.saveGState()
                    context.clip(to: lineRect)
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
        context.restoreGState()
        return true
    }

    private func page(forSurfaceOrdinal surfaceOrdinal: Int) -> NovelTextViewportIndexSurface? {
        result.viewportIndex.surfaces.first(where: { $0.surfaceOrdinal == surfaceOrdinal })
    }

    private func surfaceOriginY(page: NovelTextViewportIndexSurface) -> CGFloat? {
        if let frozenGeometry = page.frozenGeometry {
            return frozenGeometry.pageLocalOriginY
        }
        guard let firstRange = page.ranges.first,
              let documentOffset = result.viewportContext.document.documentOffset(forSurfaceRange: firstRange),
              let pageLocation = textContentStorage.location(
                textContentStorage.documentRange.location,
                offsetBy: documentOffset
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

    private func closestLayoutFragment(to point: CGPoint) -> NSTextLayoutFragment? {
        if let fragment = textLayoutManager.textLayoutFragment(for: point) {
            return fragment
        }
        var best: (distance: CGFloat, fragment: NSTextLayoutFragment)?
        textLayoutManager.enumerateTextLayoutFragments(
            from: textContentStorage.documentRange.location,
            options: []
        ) { fragment in
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
                offsetBy: frozenGeometry.documentStartOffset
            )
        }
        guard let firstRange = page.ranges.first,
              let documentOffset = result.viewportContext.document.documentOffset(forSurfaceRange: firstRange) else {
            return nil
        }
        return textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: documentOffset
        )
    }

    private func characterRange(for page: NovelTextViewportIndexSurface) -> Range<Int>? {
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

    private func intersection(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Range<Int>? {
        let lowerBound = max(lhs.lowerBound, rhs.lowerBound)
        let upperBound = min(lhs.upperBound, rhs.upperBound)
        guard upperBound > lowerBound else { return nil }
        return lowerBound..<upperBound
    }

    private func characterOffset(in text: String, fromUTF16Offset offset: Int) -> Int? {
        guard offset >= 0,
              let utf16Index = text.utf16.index(
                  text.utf16.startIndex,
                  offsetBy: offset,
                  limitedBy: text.utf16.endIndex
              ),
              let stringIndex = String.Index(utf16Index, within: text) else {
            return nil
        }
        return text.distance(from: text.startIndex, to: stringIndex)
    }

    private func utf16Range(in text: String, characterRange: Range<Int>) -> NSRange? {
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound >= characterRange.lowerBound,
              let start = text.index(text.startIndex, offsetBy: characterRange.lowerBound, limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: characterRange.upperBound, limitedBy: text.endIndex),
              let utf16Start = start.samePosition(in: text.utf16),
              let utf16End = end.samePosition(in: text.utf16) else {
            return nil
        }
        return NSRange(
            location: text.utf16.distance(from: text.utf16.startIndex, to: utf16Start),
            length: text.utf16.distance(from: utf16Start, to: utf16End)
        )
    }

    private func quoteBlockBackgroundColor() -> UIColor {
        let backgroundStyle = settings.backgroundStyle
        return UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(white: 1, alpha: 0.10)
            }

            switch backgroundStyle {
            case .system:
                return UIColor(white: 1, alpha: 0.58)
            case .paper:
                return UIColor(red: 1.0, green: 0.97, blue: 0.88, alpha: 0.68)
            case .mint:
                return UIColor(white: 1, alpha: 0.62)
            case .sakura:
                return UIColor(white: 1, alpha: 0.60)
            }
        }
    }
}
