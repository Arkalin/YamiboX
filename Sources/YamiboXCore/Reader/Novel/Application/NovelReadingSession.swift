import Foundation

package struct NovelReadingSpread: Identifiable, Equatable, Sendable {
    public let index: Int
    public let leftSurfaceIndex: Int
    public let rightSurfaceIndex: Int?
    public let chapterTitle: String?

    public var id: Int { index }

    public init(index: Int, leftSurfaceIndex: Int, rightSurfaceIndex: Int?, chapterTitle: String?) {
        self.index = max(0, index)
        self.leftSurfaceIndex = max(0, leftSurfaceIndex)
        self.rightSurfaceIndex = rightSurfaceIndex
        self.chapterTitle = chapterTitle
    }
}

package struct NovelReadingSnapshot: Equatable, Sendable {
    public var selectedSurfaceOrdinal: Int
    public var currentSurfaceIntraProgress: Double
    public var currentView: Int
    public var maxView: Int
    public var currentChapterTitle: String?
    public var retainedChapterCount: Int
    public var filteredChapterCandidateCount: Int
    public var currentAuthorID: String?

    public init(
        selectedSurfaceOrdinal: Int,
        currentSurfaceIntraProgress: Double,
        currentView: Int,
        maxView: Int,
        currentChapterTitle: String?,
        retainedChapterCount: Int,
        filteredChapterCandidateCount: Int,
        currentAuthorID: String?
    ) {
        self.selectedSurfaceOrdinal = max(0, selectedSurfaceOrdinal)
        self.currentSurfaceIntraProgress = min(max(currentSurfaceIntraProgress, 0), 1)
        self.currentView = max(1, currentView)
        self.maxView = max(self.currentView, maxView)
        self.currentChapterTitle = currentChapterTitle
        self.retainedChapterCount = max(0, retainedChapterCount)
        self.filteredChapterCandidateCount = max(0, filteredChapterCandidateCount)
        self.currentAuthorID = currentAuthorID
    }
}

package enum NovelReadingNavigationRequest: Equatable, Sendable {
    case loadView(view: Int, preferredSurfaceOrdinal: Int, resumePoint: NovelResumePoint?)
    case promotePrefetched(preferredSurfaceOrdinal: Int, resumePoint: NovelResumePoint?)
}

package struct NovelReadingSession: Sendable {
    public private(set) var snapshot: NovelReadingSnapshot

    private var currentDocument: NovelReaderProjection
    private var layoutResult: NovelTextLayoutResult?
    private var surfaces: [NovelTextViewportIndexSurface]
    private var chapters: [NovelReaderChapter]
    private var spreads: [NovelReadingSpread]
    private var usesPagedSpread: Bool
    private var pageTurnDirection: ReaderPageTurnDirection
    private var pendingResumePoint: NovelResumePoint?
    private var preservedTextResumePoint: NovelResumePoint?

    init(
        document: NovelReaderProjection,
        layoutResult: NovelTextLayoutResult,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        currentAuthorID: String? = nil,
        usesPagedSpread: Bool = false,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight
    ) {
        self.init(
            unpaginatedDocument: document,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: usesPagedSpread,
            pageTurnDirection: pageTurnDirection
        )
        preservedTextResumePoint = resumePoint
        consumeCommittedLayoutResult(
            layoutResult,
            for: document,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: resumePoint
        )
    }

    public init(
        validating document: NovelReaderProjection,
        layoutResult: NovelTextLayoutResult,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        currentAuthorID: String? = nil,
        usesPagedSpread: Bool = false,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight
    ) throws {
        self.init(
            unpaginatedDocument: document,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: usesPagedSpread,
            pageTurnDirection: pageTurnDirection
        )
        preservedTextResumePoint = resumePoint
        try validateCommittedLayoutResult(layoutResult, for: document)
        consumeCommittedLayoutResult(
            layoutResult,
            for: document,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: resumePoint
        )
    }

    private init(
        unpaginatedDocument document: NovelReaderProjection,
        currentAuthorID: String?,
        usesPagedSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection
    ) {
        self.currentDocument = document
        self.layoutResult = nil
        self.surfaces = []
        self.chapters = []
        self.spreads = []
        self.usesPagedSpread = usesPagedSpread
        self.pageTurnDirection = pageTurnDirection
        self.pendingResumePoint = nil
        self.preservedTextResumePoint = nil
        self.snapshot = NovelReadingSnapshot(
            selectedSurfaceOrdinal: 0,
            currentSurfaceIntraProgress: 0,
            currentView: document.view,
            maxView: document.maxView,
            currentChapterTitle: nil,
            retainedChapterCount: document.retainedChapterCount,
            filteredChapterCandidateCount: document.filteredChapterCandidateCount,
            currentAuthorID: document.resolvedAuthorID ?? currentAuthorID
        )
    }

    public mutating func consumeCommittedLayoutResult(
        _ layoutResult: NovelTextLayoutResult,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        usesPagedSpread: Bool? = nil,
        pageTurnDirection: ReaderPageTurnDirection? = nil
    ) {
        if let usesPagedSpread {
            self.usesPagedSpread = usesPagedSpread
        }
        if let pageTurnDirection {
            self.pageTurnDirection = pageTurnDirection
        }
        consumeCommittedLayoutResult(
            layoutResult,
            for: currentDocument,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: preferredResumePoint
        )
    }

    public mutating func consumeCommittedLayoutResult(
        _ layoutResult: NovelTextLayoutResult,
        for document: NovelReaderProjection,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?,
        usesPagedSpread: Bool? = nil,
        pageTurnDirection: ReaderPageTurnDirection? = nil
    ) {
        if let usesPagedSpread {
            self.usesPagedSpread = usesPagedSpread
        }
        if let pageTurnDirection {
            self.pageTurnDirection = pageTurnDirection
        }
        currentDocument = document
        applyCommittedLayoutResult(
            layoutResult,
            for: document,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: preferredResumePoint
        )
    }

    public mutating func selectSurface(_ surfaceOrdinal: Int) {
        updateLocation(surfaceOrdinal: surfaceOrdinal, intraSurfaceProgress: 0)
    }

    @discardableResult
    public mutating func restoreResumePoint(_ resumePoint: NovelResumePoint) -> Bool {
        guard let target = resolveResumePoint(resumePoint, in: surfaces) else {
            return false
        }
        setCurrentLocation(target)
        preserveCurrentTextResumePointIfAvailable()
        return true
    }

    @discardableResult
    public mutating func jumpRelativeSurface(_ delta: Int) -> NovelReadingNavigationRequest? {
        guard delta != 0 else { return nil }

        if layoutResult?.viewportIndex.readingMode == .paged, usesPagedSpread, !spreads.isEmpty {
            let targetSpreadIndex = spreadIndex(
                forSurfaceOrdinal: snapshot.selectedSurfaceOrdinal,
                surfaces: surfaces,
                spreads: spreads
            ) + delta
            if targetSpreadIndex >= 0, targetSpreadIndex < spreads.count {
                selectSurface(progressSurfaceIndex(forSpreadIndex: targetSpreadIndex, spreads: spreads))
                return nil
            }
            if targetSpreadIndex < 0 {
                let previousView = max(snapshot.currentView - 1, 1)
                guard previousView < snapshot.currentView else {
                    selectSurface(progressSurfaceIndex(forSpreadIndex: 0, spreads: spreads))
                    return nil
                }
                return .loadView(view: previousView, preferredSurfaceOrdinal: .max, resumePoint: nil)
            }

            let nextView = min(snapshot.currentView + 1, snapshot.maxView)
            guard nextView > snapshot.currentView else {
                selectSurface(progressSurfaceIndex(forSpreadIndex: max(spreads.count - 1, 0), spreads: spreads))
                return nil
            }
            return .loadView(view: nextView, preferredSurfaceOrdinal: 0, resumePoint: nil)
        }

        let targetIndex = snapshot.selectedSurfaceOrdinal + delta
        if targetIndex >= 0, targetIndex < surfaces.count {
            selectSurface(targetIndex)
            return nil
        }

        if targetIndex < 0 {
            let previousView = max(snapshot.currentView - 1, 1)
            guard previousView < snapshot.currentView else {
                selectSurface(0)
                return nil
            }
            return .loadView(view: previousView, preferredSurfaceOrdinal: .max, resumePoint: nil)
        }

        let nextView = min(snapshot.currentView + 1, snapshot.maxView)
        guard nextView > snapshot.currentView else {
            selectSurface(max(surfaces.count - 1, 0))
            return nil
        }
        return .loadView(view: nextView, preferredSurfaceOrdinal: 0, resumePoint: nil)
    }

    public mutating func updateVerticalViewportPosition(surfaceOrdinal: Int, intraSurfaceProgress: Double) {
        updateLocation(surfaceOrdinal: surfaceOrdinal, intraSurfaceProgress: intraSurfaceProgress)
        preserveCurrentTextResumePointIfAvailable()
    }

    public mutating func updateVerticalViewportPosition(sample: NovelTextViewportSample) {
        guard layoutResult?.viewportIndex.readingMode == .vertical,
              let target = resolveViewportSample(sample) else {
            updateVerticalViewportPosition(surfaceOrdinal: sample.surfaceIdentity.ordinal, intraSurfaceProgress: 0)
            return
        }
        setCurrentLocation(target)
        preserveCurrentTextResumePointIfAvailable()
    }

    package mutating func updateMaximumView(_ maxView: Int) {
        snapshot.maxView = max(snapshot.currentView, maxView)
    }

    public mutating func promotePrefetchedDocument(
        document nextDocument: NovelReaderProjection,
        layoutResult: NovelTextLayoutResult,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        usesPagedSpread: Bool? = nil
    ) throws {
        let effectiveResumePoint = resumePoint?.view == nextDocument.view ? resumePoint : nil
        try validateCommittedLayoutResult(layoutResult, for: nextDocument)
        if let usesPagedSpread {
            self.usesPagedSpread = usesPagedSpread
        }
        currentDocument = nextDocument
        applyCommittedLayoutResult(
            layoutResult,
            for: nextDocument,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            preferredResumePoint: effectiveResumePoint
        )
    }

    public func captureNovelReadingPosition() -> NovelResumePoint? {
        currentNovelReadingPosition() ?? preservedTextResumePoint
    }

    private func currentNovelReadingPosition() -> NovelResumePoint? {
        guard let page = selectedViewportSurface,
              let chapterOrdinal = page.chapterOrdinal,
              let position = page.semanticTextPosition(
                for: snapshot.currentSurfaceIntraProgress,
                in: currentDocument
              ) else {
            return nil
        }

        return NovelResumePoint(
            view: page.documentView,
            chapterIdentity: position.chapterIdentity,
            textSegmentIdentity: position.textSegmentIdentity,
            displayedTextOffset: position.displayedTextOffset,
            chapterOrdinal: chapterOrdinal,
            chapterTitle: page.chapterTitle,
            segmentProgress: snapshot.currentSurfaceIntraProgress,
            authorID: snapshot.currentAuthorID,
            readingModeHint: layoutResult?.viewportIndex.readingMode ?? .paged
        )
    }

    public func currentPreviewSourceText() -> String {
        guard let page = selectedViewportSurface,
              let document = document(for: page.documentView),
              !document.segments.isEmpty else {
            return ""
        }

        guard let currentPosition = page.semanticTextPosition(
            for: snapshot.currentSurfaceIntraProgress,
            in: document
        ) else {
            return ""
        }
        return document.previewSourceText(from: currentPosition)
    }

    private func chapterTitle(
        forSurfaceOrdinal surfaceOrdinal: Int,
        surfaces: [NovelTextViewportIndexSurface],
        chapters: [NovelReaderChapter]
    ) -> String? {
        guard surfaces.indices.contains(surfaceOrdinal) else {
            return chapters.last(where: { $0.startIndex <= surfaceOrdinal })?.title
        }
        return surfaces[surfaceOrdinal].chapterTitle ?? chapters.last(where: { $0.startIndex <= surfaceOrdinal })?.title
    }

    private var selectedViewportSurface: NovelTextViewportIndexSurface? {
        let normalizedIndex = normalizedPagedSurfaceOrdinal(
            snapshot.selectedSurfaceOrdinal,
            surfaces: surfaces,
            spreads: spreads
        )
        guard surfaces.indices.contains(normalizedIndex) else { return nil }
        return surfaces[normalizedIndex]
    }

    private func document(for view: Int) -> NovelReaderProjection? {
        if view == currentDocument.view {
            return currentDocument
        }
        return nil
    }

    private mutating func updateLocation(surfaceOrdinal: Int, intraSurfaceProgress: Double) {
        let normalizedSurfaceOrdinal = normalizedPagedSurfaceOrdinal(
            surfaceOrdinal,
            surfaces: surfaces,
            spreads: spreads
        )
        let target = NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: normalizedSurfaceOrdinal,
            intraSurfaceProgress: intraSurfaceProgress,
            documentView: displayedViewCandidate(for: normalizedSurfaceOrdinal, surfaces: surfaces)
        )
        setCurrentLocation(target)
    }

    private mutating func setCurrentLocation(_ target: NovelReaderResolvedSurfaceTarget) {
        let normalizedSurfaceOrdinal = normalizedPagedSurfaceOrdinal(
            target.surfaceOrdinal,
            surfaces: surfaces,
            spreads: spreads
        )
        snapshot.selectedSurfaceOrdinal = normalizedSurfaceOrdinal
        snapshot.currentSurfaceIntraProgress = min(max(target.intraSurfaceProgress, 0), 1)
        snapshot.currentChapterTitle = chapterTitle(
            forSurfaceOrdinal: normalizedSurfaceOrdinal,
            surfaces: surfaces,
            chapters: chapters
        )
    }

    private func validateCommittedLayoutResult(
        _ layoutResult: NovelTextLayoutResult,
        for document: NovelReaderProjection
    ) throws {
        guard layoutResult.viewportIndex.documentView == document.view,
              layoutResult.viewportContext.identity.documentView == document.view else {
            throw NovelTextLayoutFailure.offsetMapping
        }
    }

    private mutating func applyCommittedLayoutResult(
        _ layoutResult: NovelTextLayoutResult,
        for document: NovelReaderProjection,
        preferredSurfaceOrdinal: Int,
        preferredResumePoint: NovelResumePoint?
    ) {
        let viewportSurfaces = layoutResult.viewportIndex.surfaces
        let renderedChapters = layoutResult.viewportIndex.novelReaderChapters
        let surfaces = viewportSurfaces
        let fallbackTarget = NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: max(0, min(preferredSurfaceOrdinal, max(surfaces.count - 1, 0))),
            intraSurfaceProgress: 0,
            documentView: displayedViewCandidate(for: preferredSurfaceOrdinal, surfaces: surfaces)
        )
        let effectiveResumePoint = pendingResumePoint ?? preferredResumePoint
        let resolvedTarget = effectiveResumePoint.flatMap { resolveResumePoint($0, in: surfaces) } ?? fallbackTarget
        let spreads = makeSpreads(from: surfaces)
        let normalizedSurfaceOrdinal = normalizedPagedSurfaceOrdinal(
            resolvedTarget.surfaceOrdinal,
            surfaces: surfaces,
            spreads: spreads
        )
        self.layoutResult = layoutResult
        self.surfaces = surfaces
        self.chapters = renderedChapters
        self.spreads = spreads
        snapshot = NovelReadingSnapshot(
            selectedSurfaceOrdinal: normalizedSurfaceOrdinal,
            currentSurfaceIntraProgress: resolvedTarget.intraSurfaceProgress,
            currentView: document.view,
            maxView: document.maxView,
            currentChapterTitle: chapterTitle(
                forSurfaceOrdinal: normalizedSurfaceOrdinal,
                surfaces: surfaces,
                chapters: renderedChapters
            ),
            retainedChapterCount: document.retainedChapterCount,
            filteredChapterCandidateCount: document.filteredChapterCandidateCount,
            currentAuthorID: document.resolvedAuthorID ?? snapshot.currentAuthorID
        )
        pendingResumePoint = nil
        preserveCurrentTextResumePointIfAvailable()
    }

    package func surfaceCount(in view: Int) -> Int {
        surfaces.filter { $0.documentView == view }.count
    }

    package var viewportSurfacesForTesting: [NovelTextViewportIndexSurface] {
        surfaces
    }

    package var novelReaderChaptersForTesting: [NovelReaderChapter] {
        chapters
    }

    package var spreadsForTesting: [NovelReadingSpread] {
        spreads
    }

    package var layoutResultForTesting: NovelTextLayoutResult? {
        layoutResult
    }

    private mutating func preserveCurrentTextResumePointIfAvailable() {
        guard let resumePoint = currentNovelReadingPosition() else { return }
        preservedTextResumePoint = resumePoint
    }

    private func displayedViewCandidate(for preferredSurfaceOrdinal: Int, surfaces: [NovelTextViewportIndexSurface]) -> Int {
        let spreads = makeSpreads(from: surfaces)
        let normalizedIndex = normalizedPagedSurfaceOrdinal(preferredSurfaceOrdinal, surfaces: surfaces, spreads: spreads)
        guard surfaces.indices.contains(normalizedIndex) else {
            return currentDocument.view
        }
        return surfaces[normalizedIndex].documentView
    }

    private func makeSpreads(from surfaces: [NovelTextViewportIndexSurface]) -> [NovelReadingSpread] {
        guard !surfaces.isEmpty else { return [] }

        var spreads: [NovelReadingSpread] = []
        var surfaceCursor = 0

        while surfaceCursor < surfaces.count {
            let leftSurface = surfaces[surfaceCursor]
            let candidateRightIndex = surfaceCursor + 1
            let rightSurfaceIndex: Int? = if surfaces.indices.contains(candidateRightIndex),
                                          surfaces[candidateRightIndex].documentView == leftSurface.documentView {
                candidateRightIndex
            } else {
                nil
            }

            spreads.append(
                NovelReadingSpread(
                    index: spreads.count,
                    leftSurfaceIndex: leftSurface.surfaceOrdinal,
                    rightSurfaceIndex: rightSurfaceIndex,
                    chapterTitle: leftSurface.chapterTitle
                )
            )
            surfaceCursor += rightSurfaceIndex == nil ? 1 : 2
        }

        return spreads
    }

    private func spreadIndex(
        forSurfaceOrdinal surfaceOrdinal: Int,
        surfaces: [NovelTextViewportIndexSurface],
        spreads: [NovelReadingSpread]
    ) -> Int {
        guard usesPagedSpread else {
            return max(0, min(surfaceOrdinal, max(surfaces.count - 1, 0)))
        }

        let normalizedIndex = max(0, min(surfaceOrdinal, max(surfaces.count - 1, 0)))
        return spreads.first(where: { spread in
            spread.leftSurfaceIndex == normalizedIndex || spread.rightSurfaceIndex == normalizedIndex
        })?.index ?? 0
    }

    private func progressSurfaceIndex(forSpreadIndex spreadIndex: Int, spreads: [NovelReadingSpread]) -> Int {
        guard let spread = spreads.first(where: { $0.index == spreadIndex }) ?? spreads.last else {
            return 0
        }
        switch pageTurnDirection {
        case .leftToRight:
            return spread.rightSurfaceIndex ?? spread.leftSurfaceIndex
        case .rightToLeft:
            return spread.leftSurfaceIndex
        }
    }

    private func normalizedPagedSurfaceOrdinal(
        _ surfaceOrdinal: Int,
        surfaces: [NovelTextViewportIndexSurface],
        spreads: [NovelReadingSpread]
    ) -> Int {
        let clampedIndex = max(0, min(surfaceOrdinal, max(surfaces.count - 1, 0)))
        guard usesPagedSpread else { return clampedIndex }
        return progressSurfaceIndex(
            forSpreadIndex: spreadIndex(forSurfaceOrdinal: clampedIndex, surfaces: surfaces, spreads: spreads),
            spreads: spreads
        )
    }

    private func resolveResumePoint(
        _ resumePoint: NovelResumePoint,
        in indexedSurfaces: [NovelTextViewportIndexSurface]
    ) -> NovelReaderResolvedSurfaceTarget? {
        let surfacesInView = indexedSurfaces.filter { $0.documentView == resumePoint.view }
        guard !surfacesInView.isEmpty else {
            return nil
        }

        if let textSegmentIdentity = resumePoint.textSegmentIdentity {
            if let target = resolveTextSegmentIdentity(
                textSegmentIdentity,
                displayedTextOffset: resumePoint.displayedTextOffset,
                resumePoint: resumePoint,
                surfacesInView: surfacesInView
            ) {
                return target
            }
            if let target = resolveImageSegmentIdentity(
                textSegmentIdentity,
                surfacesInView: surfacesInView
            ) {
                return target
            }
        }

        if let chapterIdentity = resumePoint.chapterIdentity,
           let target = resolveChapterIdentity(
            chapterIdentity,
            resumePoint: resumePoint,
            surfacesInView: surfacesInView
           ) {
            return target
        }

        if let target = resolveFilteredAuthorReplyFallback(
            resumePoint,
            surfacesInView: surfacesInView
        ) {
            return target
        }

        if let chapterSurface = surfacesInView.first(where: { $0.chapterOrdinal == resumePoint.chapterOrdinal }) {
            return NovelReaderResolvedSurfaceTarget(
                surfaceOrdinal: chapterSurface.surfaceOrdinal,
                intraSurfaceProgress: min(max(resumePoint.segmentProgress, 0), 1),
                documentView: chapterSurface.documentView
            )
        }

        if let firstTextSurface = surfacesInView.first(where: \.containsText) {
            return NovelReaderResolvedSurfaceTarget(
                surfaceOrdinal: firstTextSurface.surfaceOrdinal,
                intraSurfaceProgress: 0,
                documentView: firstTextSurface.documentView
            )
        }

        guard let firstSurface = surfacesInView.first else { return nil }
        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: firstSurface.surfaceOrdinal,
            intraSurfaceProgress: 0,
            documentView: firstSurface.documentView
        )
    }

    private func resolveTextSegmentIdentity(
        _ textSegmentIdentity: NovelTextSegmentIdentity,
        displayedTextOffset: Int,
        resumePoint: NovelResumePoint,
        surfacesInView: [NovelTextViewportIndexSurface]
    ) -> NovelReaderResolvedSurfaceTarget? {
        let candidateSurfaces = surfacesInView.filter { surface in
            surface.contains(textSegmentIdentity: textSegmentIdentity, in: currentDocument)
        }
        let containingSurface = candidateSurfaces.first { surface in
            surface.contains(
                textSegmentIdentity: textSegmentIdentity,
                displayedTextOffset: displayedTextOffset,
                in: currentDocument
            )
        }
        if let containingSurface {
            return NovelReaderResolvedSurfaceTarget(
                surfaceOrdinal: containingSurface.surfaceOrdinal,
                intraSurfaceProgress: containingSurface.intraSurfaceProgress(
                    displayedTextOffset: displayedTextOffset,
                    textSegmentIdentity: textSegmentIdentity,
                    fallbackProgress: resumePoint.segmentProgress,
                    in: currentDocument
                ),
                documentView: containingSurface.documentView
            )
        }
        guard let nearestSurface = candidateSurfaces.min(by: {
            $0.distance(
                from: displayedTextOffset,
                textSegmentIdentity: textSegmentIdentity,
                in: currentDocument
            ) < $1.distance(
                from: displayedTextOffset,
                textSegmentIdentity: textSegmentIdentity,
                in: currentDocument
            )
        }) else {
            return nil
        }
        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: nearestSurface.surfaceOrdinal,
            intraSurfaceProgress: nearestSurface.intraSurfaceProgress(
                displayedTextOffset: displayedTextOffset,
                textSegmentIdentity: textSegmentIdentity,
                fallbackProgress: resumePoint.segmentProgress,
                in: currentDocument
            ),
            documentView: nearestSurface.documentView
        )
    }

    /// A liked image's resume point stores the image's identity in the same
    /// `textSegmentIdentity` field text resume points use (see
    /// `NovelImageLikeAnchor.imageSegmentIdentity`), but the image itself
    /// lives on a surface's `externalBlocks`, not its `ranges` — so it never
    /// matches `resolveTextSegmentIdentity` above. Without this, an image
    /// resume point always falls through to `resolveChapterIdentity`, which
    /// lands on the first surface of the chapter rather than the liked image.
    private func resolveImageSegmentIdentity(
        _ imageSegmentIdentity: NovelTextSegmentIdentity,
        surfacesInView: [NovelTextViewportIndexSurface]
    ) -> NovelReaderResolvedSurfaceTarget? {
        guard let surface = surfacesInView.first(where: {
            $0.contains(imageSegmentIdentity: imageSegmentIdentity)
        }) else {
            return nil
        }
        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: surface.surfaceOrdinal,
            intraSurfaceProgress: 0,
            documentView: surface.documentView
        )
    }

    private func resolveChapterIdentity(
        _ chapterIdentity: NovelChapterIdentity,
        resumePoint: NovelResumePoint,
        surfacesInView: [NovelTextViewportIndexSurface]
    ) -> NovelReaderResolvedSurfaceTarget? {
        guard let chapterSurface = surfacesInView.first(where: { surface in
            surface.contains(chapterIdentity: chapterIdentity, in: currentDocument)
        }) else {
            return nil
        }
        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: chapterSurface.surfaceOrdinal,
            intraSurfaceProgress: min(max(resumePoint.segmentProgress, 0), 1),
            documentView: chapterSurface.documentView
        )
    }

    private func resolveFilteredAuthorReplyFallback(
        _ resumePoint: NovelResumePoint,
        surfacesInView: [NovelTextViewportIndexSurface]
    ) -> NovelReaderResolvedSurfaceTarget? {
        guard let textSegmentIdentity = resumePoint.textSegmentIdentity,
              let hiddenSegmentIndex = currentDocument.segmentSemantics.firstIndex(where: {
                  $0?.textSegmentIdentity == textSegmentIdentity
              }),
              currentDocument.source(forSegmentIndex: hiddenSegmentIndex)?.isAuthorReplyToOther == true else {
            return nil
        }

        let visibleRanges = surfacesInView.flatMap { surface in
            surface.ranges.compactMap { range -> (surface: NovelTextViewportIndexSurface, range: NovelRenderedTextRange)? in
                guard currentDocument.source(forSegmentIndex: range.segmentIndex)?.isAuthorReplyToOther != true,
                      currentDocument.semantics(forSegmentIndex: range.segmentIndex)?.textSegmentIdentity != nil else {
                    return nil
                }
                return (surface, range)
            }
        }

        if let previous = visibleRanges
            .filter({ $0.range.segmentIndex < hiddenSegmentIndex })
            .max(by: nearestVisibleRangeSort) {
            return resolvedSurfaceTarget(
                surface: previous.surface,
                range: previous.range,
                displayedTextOffset: previous.range.endOffset,
                fallbackProgress: 1
            )
        }

        if let next = visibleRanges
            .filter({ $0.range.segmentIndex > hiddenSegmentIndex })
            .min(by: nearestVisibleRangeSort) {
            return resolvedSurfaceTarget(
                surface: next.surface,
                range: next.range,
                displayedTextOffset: next.range.startOffset,
                fallbackProgress: 0
            )
        }

        return nil
    }

    private func nearestVisibleRangeSort(
        _ lhs: (surface: NovelTextViewportIndexSurface, range: NovelRenderedTextRange),
        _ rhs: (surface: NovelTextViewportIndexSurface, range: NovelRenderedTextRange)
    ) -> Bool {
        if lhs.range.segmentIndex != rhs.range.segmentIndex {
            return lhs.range.segmentIndex < rhs.range.segmentIndex
        }
        if lhs.surface.surfaceOrdinal != rhs.surface.surfaceOrdinal {
            return lhs.surface.surfaceOrdinal < rhs.surface.surfaceOrdinal
        }
        return lhs.range.startOffset < rhs.range.startOffset
    }

    private func resolvedSurfaceTarget(
        surface: NovelTextViewportIndexSurface,
        range: NovelRenderedTextRange,
        displayedTextOffset: Int,
        fallbackProgress: Double
    ) -> NovelReaderResolvedSurfaceTarget? {
        guard let textSegmentIdentity = currentDocument
            .semantics(forSegmentIndex: range.segmentIndex)?
            .textSegmentIdentity else {
            return nil
        }
        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: surface.surfaceOrdinal,
            intraSurfaceProgress: surface.intraSurfaceProgress(
                displayedTextOffset: displayedTextOffset,
                textSegmentIdentity: textSegmentIdentity,
                fallbackProgress: fallbackProgress,
                in: currentDocument
            ),
            documentView: surface.documentView
        )
    }

    private func resolveViewportSample(_ sample: NovelTextViewportSample) -> NovelReaderResolvedSurfaceTarget? {
        guard let surface = surfaces.first(where: {
            $0.surfaceOrdinal == sample.surfaceIdentity.ordinal && $0.documentView == sample.documentView
        }) else {
            return nil
        }

        guard surface.contains(
            textSegmentIdentity: sample.textSegmentIdentity,
            displayedTextOffset: sample.displayedTextOffset,
            in: currentDocument
        ) else {
            return nil
        }

        return NovelReaderResolvedSurfaceTarget(
            surfaceOrdinal: surface.surfaceOrdinal,
            intraSurfaceProgress: surface.intraSurfaceProgress(
                displayedTextOffset: sample.displayedTextOffset,
                textSegmentIdentity: sample.textSegmentIdentity,
                fallbackProgress: 0,
                in: currentDocument
            ),
            documentView: surface.documentView
        )
    }

}

private struct NovelReaderResolvedSurfaceTarget {
    let surfaceOrdinal: Int
    let intraSurfaceProgress: Double
    let documentView: Int
}
