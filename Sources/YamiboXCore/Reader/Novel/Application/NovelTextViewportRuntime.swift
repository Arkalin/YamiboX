import CoreGraphics
import Foundation

package struct NovelTextViewportRuntimeDiagnostics: Equatable, Sendable {
    public var contentStorageCount: Int
    public var activeLayoutManagerCount: Int
    public var perSurfaceTextKitDocumentCount: Int
    public var semanticAttributedDocumentCacheCount: Int
    public var viewportControllerCount: Int
    public var currentActivePlusCandidateGraphCount: Int
    public var peakActivePlusCandidateGraphCount: Int
    public var postCommitFullLayoutCount: Int
    public var viewportUpdateCount: Int
    public var rematerializedSurfaceCount: Int
    public var drawingAccessCount: Int
    public var staleDrawingAttemptCount: Int
    public var lastDrawnSurfaceIdentity: NovelReaderSurfaceIdentity?
    public var lastDrawnDocumentRange: Range<Int>?

    public init(
        contentStorageCount: Int,
        activeLayoutManagerCount: Int,
        perSurfaceTextKitDocumentCount: Int,
        semanticAttributedDocumentCacheCount: Int = 0,
        viewportControllerCount: Int? = nil,
        currentActivePlusCandidateGraphCount: Int? = nil,
        peakActivePlusCandidateGraphCount: Int? = nil,
        postCommitFullLayoutCount: Int = 0,
        viewportUpdateCount: Int = 0,
        rematerializedSurfaceCount: Int = 0,
        drawingAccessCount: Int = 0,
        staleDrawingAttemptCount: Int = 0,
        lastDrawnSurfaceIdentity: NovelReaderSurfaceIdentity? = nil,
        lastDrawnDocumentRange: Range<Int>? = nil
    ) {
        self.contentStorageCount = max(0, contentStorageCount)
        self.activeLayoutManagerCount = max(0, activeLayoutManagerCount)
        self.perSurfaceTextKitDocumentCount = max(0, perSurfaceTextKitDocumentCount)
        self.semanticAttributedDocumentCacheCount = max(0, semanticAttributedDocumentCacheCount)
        self.viewportControllerCount = max(0, viewportControllerCount ?? activeLayoutManagerCount)
        self.currentActivePlusCandidateGraphCount = max(0, currentActivePlusCandidateGraphCount ?? contentStorageCount)
        self.peakActivePlusCandidateGraphCount = max(0, peakActivePlusCandidateGraphCount ?? contentStorageCount)
        self.postCommitFullLayoutCount = max(0, postCommitFullLayoutCount)
        self.viewportUpdateCount = max(0, viewportUpdateCount)
        self.rematerializedSurfaceCount = max(0, rematerializedSurfaceCount)
        self.drawingAccessCount = max(0, drawingAccessCount)
        self.staleDrawingAttemptCount = max(0, staleDrawingAttemptCount)
        self.lastDrawnSurfaceIdentity = lastDrawnSurfaceIdentity
        self.lastDrawnDocumentRange = lastDrawnDocumentRange
    }
}

package struct NovelTextViewportRuntimeTransactionDiagnostics: Equatable, Sendable {
    public var committedTransactionCount: Int
    public var supersededTransactionCount: Int
    public var failedTransactionCount: Int
    public var lastFailureStage: NovelTextLayoutFailureStage?
    public var semanticAttributedDocumentBuildCount: Int
    public var semanticAttributedDocumentReuseCount: Int
    public var candidateIndexingPassCount: Int
    public var postIndexCompactionCount: Int
    public var geometryDeviationCount: Int

    public init(
        committedTransactionCount: Int = 0,
        supersededTransactionCount: Int = 0,
        failedTransactionCount: Int = 0,
        lastFailureStage: NovelTextLayoutFailureStage? = nil,
        semanticAttributedDocumentBuildCount: Int = 0,
        semanticAttributedDocumentReuseCount: Int = 0,
        candidateIndexingPassCount: Int? = nil,
        postIndexCompactionCount: Int? = nil,
        geometryDeviationCount: Int = 0
    ) {
        self.committedTransactionCount = max(0, committedTransactionCount)
        self.supersededTransactionCount = max(0, supersededTransactionCount)
        self.failedTransactionCount = max(0, failedTransactionCount)
        self.lastFailureStage = lastFailureStage
        self.semanticAttributedDocumentBuildCount = max(0, semanticAttributedDocumentBuildCount)
        self.semanticAttributedDocumentReuseCount = max(0, semanticAttributedDocumentReuseCount)
        self.candidateIndexingPassCount = max(0, candidateIndexingPassCount ?? committedTransactionCount)
        self.postIndexCompactionCount = max(0, postIndexCompactionCount ?? committedTransactionCount)
        self.geometryDeviationCount = max(0, geometryDeviationCount)
    }
}

package struct NovelTextLayoutRuntimeAdapterInput {
    package var preparedInput: NovelTextLayoutPreparedInput
    package var precomputedResult: NovelTextLayoutResult?
    package var settings: NovelReaderAppearanceSettings
    package var layout: NovelReaderLayout
    package var cachedSemanticAttributedDocument: NSAttributedString?

    package init(
        preparedInput: NovelTextLayoutPreparedInput,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        cachedSemanticAttributedDocument: NSAttributedString?,
        precomputedResult: NovelTextLayoutResult? = nil
    ) {
        self.preparedInput = preparedInput
        self.precomputedResult = precomputedResult
        self.settings = settings
        self.layout = layout
        self.cachedSemanticAttributedDocument = cachedSemanticAttributedDocument
    }
}

/// One live platform text-layout object graph for exactly one runtime
/// generation. Implemented by the UI layer's TextKit adapter; Core only
/// forwards geometry queries and drawing through this seam.
package protocol NovelTextViewportRuntimeGraph: AnyObject {
    func viewportSample(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelTextViewportSample?

    func referenceY(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        position: NovelResumePoint
    ) -> CGFloat?

    func characterDocumentOffset(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> Int?

    func selectionRects(
        for selectionRange: NovelTextSelectionRange,
        surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> [CGRect]

    func drawBlockBackgrounds(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    )

    @discardableResult
    func draw(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    ) -> Bool
}

package final class NovelTextLayoutRuntimeCandidate {
    package let result: NovelTextLayoutResult?
    package let semanticAttributedDocument: NSAttributedString?
    package let reusedSemanticAttributedDocument: Bool
    package let fullDocumentLayoutPassCount: Int
    package let postIndexCompactionCount: Int
    package let geometryDeviationCount: Int
    package let ownsAuthoritativeIndex: Bool
    package let graph: (any NovelTextViewportRuntimeGraph)?

    package init(
        result: NovelTextLayoutResult? = nil,
        semanticAttributedDocument: NSAttributedString? = nil,
        reusedSemanticAttributedDocument: Bool = false,
        fullDocumentLayoutPassCount: Int = 1,
        postIndexCompactionCount: Int = 1,
        geometryDeviationCount: Int = 0,
        ownsAuthoritativeIndex: Bool = false,
        graph: (any NovelTextViewportRuntimeGraph)? = nil
    ) {
        self.result = result
        self.semanticAttributedDocument = semanticAttributedDocument
        self.reusedSemanticAttributedDocument = reusedSemanticAttributedDocument
        self.fullDocumentLayoutPassCount = max(0, fullDocumentLayoutPassCount)
        self.postIndexCompactionCount = max(0, postIndexCompactionCount)
        self.geometryDeviationCount = max(0, geometryDeviationCount)
        self.ownsAuthoritativeIndex = ownsAuthoritativeIndex
        self.graph = graph
    }
}

private extension NovelTextLayoutRuntimeCandidate {
    var textKitGraphCount: Int {
        graph == nil ? 0 : 1
    }
}

/// Caller-isolated (non-`Sendable`) seam between the runtime owner and the
/// platform TextKit implementation. The production adapter lives in
/// `YamiboXUI`; tests substitute their own adapters.
package protocol NovelTextLayoutRuntimeAdapter: AnyObject {
    func prepareCandidate(
        input: NovelTextLayoutRuntimeAdapterInput
    ) throws -> NovelTextLayoutRuntimeCandidate
}

package final class NovelTextViewportRuntimeTransaction {
    private enum State {
        case pending
        case committed
        case superseded
    }

    package let generation: UInt64
    package let result: NovelTextLayoutResult
    let projection: NovelReaderProjection?
    let settings: NovelReaderAppearanceSettings
    let layout: NovelReaderLayout
    private(set) var semanticAttributedDocument: NSAttributedString?
    let reusedSemanticAttributedDocument: Bool
    let fullDocumentLayoutPassCount: Int
    let postIndexCompactionCount: Int
    private(set) var geometryDeviationCount: Int
    let ownsAuthoritativeIndex: Bool
    private(set) var graph: (any NovelTextViewportRuntimeGraph)?
    private var state = State.pending

    init(
        generation: UInt64,
        result: NovelTextLayoutResult,
        projection: NovelReaderProjection?,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        candidate: NovelTextLayoutRuntimeCandidate
    ) {
        self.generation = generation
        self.result = result
        self.projection = projection
        self.settings = settings
        self.layout = layout
        semanticAttributedDocument = candidate.semanticAttributedDocument
        reusedSemanticAttributedDocument = candidate.reusedSemanticAttributedDocument
        fullDocumentLayoutPassCount = candidate.fullDocumentLayoutPassCount
        postIndexCompactionCount = candidate.postIndexCompactionCount
        geometryDeviationCount = candidate.geometryDeviationCount
        ownsAuthoritativeIndex = candidate.ownsAuthoritativeIndex
        graph = candidate.graph
    }

    func markCommitted() -> Bool {
        guard case .pending = state else { return false }
        state = .committed
        return true
    }

    func supersede() -> Bool {
        guard case .pending = state else { return false }
        state = .superseded
        semanticAttributedDocument = nil
        graph = nil
        return true
    }

    fileprivate func prepareInitialViewport(around surfaceOrdinal: Int) throws {
        guard ownsAuthoritativeIndex else { return }
        _ = surfaceOrdinal
    }
}

private extension NovelTextViewportRuntimeTransaction {
    var textKitGraphCount: Int {
        graph == nil ? 0 : 1
    }
}

package final class NovelTextViewportRuntimeOwner {
    private var activeGeneration: UInt64 = 0
    private var nextGeneration: UInt64 = 1
    private var result: NovelTextLayoutResult?
    private var projection: NovelReaderProjection?
    private var settings = NovelReaderAppearanceSettings()
    private var layout = NovelReaderLayout(width: 1, height: 1)
    private var visibleSurfaceOrdinals = Set<Int>()
    private var semanticAttributedDocumentCache: NSAttributedString?
    private var transactionDiagnostics = NovelTextViewportRuntimeTransactionDiagnostics()
    private var peakActivePlusCandidateGraphCount = 0
    private var viewportUpdateCount = 0
    private var rematerializedSurfaceCount = 0
    private var drawingAccessCount = 0
    private var staleDrawingAttemptCount = 0
    private var lastDrawnSurfaceIdentity: NovelReaderSurfaceIdentity?
    private var lastDrawnDocumentRange: Range<Int>?
    private let adapter: any NovelTextLayoutRuntimeAdapter
    private var pendingTransaction: NovelTextViewportRuntimeTransaction?
    private var activeGraph: (any NovelTextViewportRuntimeGraph)?

    package init(adapter: any NovelTextLayoutRuntimeAdapter) {
        self.adapter = adapter
    }

    package var diagnostics: NovelTextViewportRuntimeDiagnostics {
        NovelTextViewportRuntimeDiagnostics(
            contentStorageCount: activeTextKitGraphCount,
            activeLayoutManagerCount: activeTextKitGraphCount,
            perSurfaceTextKitDocumentCount: 0,
            semanticAttributedDocumentCacheCount: semanticAttributedDocumentCache == nil ? 0 : 1,
            viewportControllerCount: activeTextKitGraphCount,
            currentActivePlusCandidateGraphCount: activeTextKitGraphCount + pendingTextKitGraphCount,
            peakActivePlusCandidateGraphCount: peakActivePlusCandidateGraphCount,
            postCommitFullLayoutCount: 0,
            viewportUpdateCount: viewportUpdateCount,
            rematerializedSurfaceCount: rematerializedSurfaceCount,
            drawingAccessCount: drawingAccessCount,
            staleDrawingAttemptCount: staleDrawingAttemptCount,
            lastDrawnSurfaceIdentity: lastDrawnSurfaceIdentity,
            lastDrawnDocumentRange: lastDrawnDocumentRange
        )
    }

    package var runtimeTransactionDiagnostics: NovelTextViewportRuntimeTransactionDiagnostics {
        transactionDiagnostics
    }

    package var currentResult: NovelTextLayoutResult? {
        result
    }

    package var currentGeneration: UInt64 {
        activeGeneration
    }

    private var activeTextKitGraphCount: Int {
        activeGraph == nil ? 0 : 1
    }

    private var pendingTextKitGraphCount: Int {
        pendingTransaction?.textKitGraphCount ?? 0
    }

    package func prepareTransaction(
        preparedInput: NovelTextLayoutPreparedInput
    ) throws -> NovelTextViewportRuntimeTransaction {
        supersedePendingTransaction()
        pendingTransaction = nil
        let generation = nextGeneration
        nextGeneration &+= 1
        let candidate: NovelTextLayoutRuntimeCandidate
        do {
            candidate = try adapter.prepareCandidate(
                input: NovelTextLayoutRuntimeAdapterInput(
                    preparedInput: preparedInput,
                    settings: preparedInput.settings,
                    layout: preparedInput.layout,
                    cachedSemanticAttributedDocument: reusableSemanticAttributedDocument(
                        for: preparedInput
                    )
                )
            )
        } catch let failure as NovelTextLayoutFailure {
            recordFailure(failure)
            throw failure
        } catch {
            let failure = NovelTextLayoutFailure.textKitIndexing
            recordFailure(failure)
            throw failure
        }
        guard let result = candidate.result else {
            let failure = NovelTextLayoutFailure.textKitIndexing
            recordFailure(failure)
            throw failure
        }
        peakActivePlusCandidateGraphCount = max(
            peakActivePlusCandidateGraphCount,
            activeTextKitGraphCount + candidate.textKitGraphCount
        )
        let transaction = NovelTextViewportRuntimeTransaction(
            generation: generation,
            result: result,
            projection: preparedInput.document,
            settings: preparedInput.settings,
            layout: preparedInput.layout,
            candidate: candidate
        )
        pendingTransaction = transaction
        return transaction
    }

    @discardableResult
    package func commit(_ transaction: NovelTextViewportRuntimeTransaction) -> Bool {
        guard pendingTransaction === transaction,
              transaction.markCommitted() else { return false }
        pendingTransaction = nil
        activeGeneration = transaction.generation
        result = transaction.result
        projection = transaction.projection
        settings = transaction.settings
        layout = transaction.layout
        semanticAttributedDocumentCache = transaction.semanticAttributedDocument
        activeGraph = transaction.graph
        transactionDiagnostics.committedTransactionCount += 1
        if transaction.reusedSemanticAttributedDocument {
            transactionDiagnostics.semanticAttributedDocumentReuseCount += 1
        } else if transaction.semanticAttributedDocument != nil {
            transactionDiagnostics.semanticAttributedDocumentBuildCount += 1
        }
        transactionDiagnostics.candidateIndexingPassCount += transaction.fullDocumentLayoutPassCount
        transactionDiagnostics.postIndexCompactionCount += transaction.postIndexCompactionCount
        transactionDiagnostics.geometryDeviationCount += transaction.geometryDeviationCount
        peakActivePlusCandidateGraphCount = max(peakActivePlusCandidateGraphCount, activeTextKitGraphCount)
        return true
    }

    package func prepareInitialViewport(
        for transaction: NovelTextViewportRuntimeTransaction,
        around surfaceOrdinal: Int
    ) throws {
        guard pendingTransaction === transaction else { return }
        do {
            try transaction.prepareInitialViewport(around: surfaceOrdinal)
        } catch let failure as NovelTextLayoutFailure {
            _ = transaction.supersede()
            pendingTransaction = nil
            recordFailure(failure)
            throw failure
        } catch {
            _ = transaction.supersede()
            pendingTransaction = nil
            let failure = NovelTextLayoutFailure.geometryValidation
            recordFailure(failure)
            throw failure
        }
    }

    private func reusableSemanticAttributedDocument(
        for preparedInput: NovelTextLayoutPreparedInput
    ) -> NSAttributedString? {
        guard result?.viewportContext.document == preparedInput.viewportContextSeed.document,
              settings == preparedInput.settings else {
            return nil
        }
        return semanticAttributedDocumentCache
    }

    package func release() {
        supersedePendingTransaction()
        pendingTransaction = nil
        result = nil
        projection = nil
        visibleSurfaceOrdinals.removeAll(keepingCapacity: false)
        semanticAttributedDocumentCache = nil
        peakActivePlusCandidateGraphCount = 0
        viewportUpdateCount = 0
        rematerializedSurfaceCount = 0
        drawingAccessCount = 0
        staleDrawingAttemptCount = 0
        lastDrawnSurfaceIdentity = nil
        lastDrawnDocumentRange = nil
        activeGraph = nil
    }

    private func supersedePendingTransaction() {
        guard pendingTransaction?.supersede() == true else { return }
        transactionDiagnostics.supersededTransactionCount += 1
    }

    private func recordFailure(_ failure: NovelTextLayoutFailure) {
        transactionDiagnostics.failedTransactionCount += 1
        transactionDiagnostics.lastFailureStage = failure.stage
    }

    package func handleMemoryPressure() {
        supersedePendingTransaction()
        pendingTransaction = nil
        semanticAttributedDocumentCache = nil
    }

    package func updateVisibleSurfaceIdentities(_ surfaceIdentities: [NovelReaderSurfaceIdentity]) {
        let visibleOrdinals = Set<Int>(surfaceIdentities.compactMap { surfaceIdentity -> Int? in
            guard surfaceIdentity.generation == activeGeneration,
                  result?.viewportIndex.surfaces.contains(where: { $0.surfaceOrdinal == surfaceIdentity.ordinal }) == true else {
                return nil
            }
            return surfaceIdentity.ordinal
        })
        let nextVisibleSurfaceOrdinals = preheatedSurfaceOrdinals(around: visibleOrdinals)
        guard visibleSurfaceOrdinals != nextVisibleSurfaceOrdinals else { return }
        visibleSurfaceOrdinals = nextVisibleSurfaceOrdinals
        viewportUpdateCount += 1
        rematerializedSurfaceCount = visibleSurfaceOrdinals.count
    }

    private func preheatedSurfaceOrdinals(around visibleOrdinals: Set<Int>) -> Set<Int> {
        guard let pages = result?.viewportIndex.surfaces, !visibleOrdinals.isEmpty else { return [] }
        let validOrdinals = Set(pages.map(\.surfaceOrdinal))
        var preheated = visibleOrdinals.intersection(validOrdinals)
        if let first = visibleOrdinals.min(), validOrdinals.contains(first - 1) {
            preheated.insert(first - 1)
        }
        if let last = visibleOrdinals.max(), validOrdinals.contains(last + 1) {
            preheated.insert(last + 1)
        }
        return preheated
    }

    private func prepareSurfaceForDrawing(_ surfaceOrdinal: Int) {
        guard !visibleSurfaceOrdinals.contains(surfaceOrdinal) else { return }
        visibleSurfaceOrdinals = preheatedSurfaceOrdinals(around: [surfaceOrdinal])
        viewportUpdateCount += 1
        rematerializedSurfaceCount = visibleSurfaceOrdinals.count
    }

    package func isCurrent(_ surfaceIdentity: NovelReaderSurfaceIdentity) -> Bool {
        surfaceIdentity.generation == activeGeneration &&
            result?.viewportIndex.surfaces.contains(where: {
                $0.surfaceOrdinal == surfaceIdentity.ordinal
            }) == true
    }

    package func viewportSample(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelTextViewportSample? {
        guard isCurrent(surfaceIdentity) else { return nil }
        return activeGraph?.viewportSample(
            surfaceIdentity: surfaceIdentity,
            referencePoint: referencePoint
        )
    }

    package func referenceY(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        position: NovelResumePoint
    ) -> CGFloat? {
        guard isCurrent(surfaceIdentity) else { return nil }
        return activeGraph?.referenceY(
            surfaceIdentity: surfaceIdentity,
            position: position
        )
    }

    package func selectionAnchor(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        referencePoint: CGPoint
    ) -> NovelTextSelectionAnchor? {
        guard isCurrent(surfaceIdentity),
              let documentOffset = activeGraph?.characterDocumentOffset(
                  surfaceIdentity: surfaceIdentity,
                  referencePoint: referencePoint
              ) else {
            return nil
        }
        return NovelTextSelectionAnchor(
            generation: surfaceIdentity.generation,
            documentOffset: documentOffset
        )
    }

    package func selectionRects(
        for selectionRange: NovelTextSelectionRange,
        surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> [CGRect] {
        guard selectionRange.generation == activeGeneration,
              isCurrent(surfaceIdentity) else {
            return []
        }
        return activeGraph?.selectionRects(
            for: selectionRange,
            surfaceIdentity: surfaceIdentity
        ) ?? []
    }

    package func expandedSelectionRange(
        around anchor: NovelTextSelectionAnchor
    ) -> NovelTextSelectionRange? {
        guard anchor.generation == activeGeneration,
              let text = result?.viewportContext.document.text,
              !text.isEmpty,
              let characterRange = selectableCharacterRange(around: anchor.documentOffset, in: text) else {
            return nil
        }
        return NovelTextSelectionRange(
            generation: anchor.generation,
            lowerBound: characterRange.lowerBound,
            upperBound: characterRange.upperBound
        )
    }

    package func selectionRange(
        from start: NovelTextSelectionAnchor,
        to end: NovelTextSelectionAnchor
    ) -> NovelTextSelectionRange? {
        guard start.generation == activeGeneration,
              end.generation == activeGeneration,
              let text = result?.viewportContext.document.text else {
            return nil
        }
        let lowerBound = min(start.documentOffset, end.documentOffset)
        let upperBound = max(start.documentOffset, end.documentOffset)
        return NovelTextSelectionRange(
            generation: start.generation,
            lowerBound: min(max(lowerBound, 0), text.count),
            upperBound: min(max(upperBound, 0), text.count)
        )
    }

    package func selectedText(for selectionRange: NovelTextSelectionRange) -> String? {
        guard selectionRange.generation == activeGeneration,
              let text = result?.viewportContext.document.text,
              let start = text.index(text.startIndex, offsetBy: selectionRange.lowerBound, limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: selectionRange.upperBound, limitedBy: text.endIndex),
              start < end else {
            return nil
        }
        return String(text[start..<end])
    }

    /// Converts a persisted Like highlight's start/end into a selection range
    /// in the active generation's document-offset space, reusing the same
    /// geometry `selectionRects(for:surfaceIdentity:)` already draws with. A
    /// persisted Like anchor never carries which forum page (`view`) it came
    /// from, so both endpoints' `view` are overridden to the active
    /// document's own `view` before lookup; content that isn't part of the
    /// active document simply fails the segment-identity lookup inside
    /// `documentOffset(for:in:)`, which is the desired "not on this page,
    /// don't render" behavior rather than an error.
    package func documentSelectionRange(
        from start: NovelResumePoint,
        to end: NovelResumePoint
    ) -> NovelTextSelectionRange? {
        guard let projection, let result else { return nil }
        var start = start
        var end = end
        start.view = projection.view
        end.view = projection.view
        guard let startOffset = result.viewportContext.document.documentOffset(for: start, in: projection),
              let endOffset = result.viewportContext.document.documentOffset(for: end, in: projection) else {
            return nil
        }
        return NovelTextSelectionRange(
            generation: activeGeneration,
            lowerBound: min(startOffset, endOffset),
            upperBound: max(startOffset, endOffset)
        )
    }

    package func drawBlockBackgrounds(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    ) {
        guard isCurrent(surfaceIdentity) else {
            staleDrawingAttemptCount += 1
            return
        }
        prepareSurfaceForDrawing(surfaceIdentity.ordinal)
        activeGraph?.drawBlockBackgrounds(
            surfaceIdentity: surfaceIdentity,
            in: context,
            bounds: bounds
        )
    }

    package func draw(
        surfaceIdentity: NovelReaderSurfaceIdentity,
        in context: CGContext,
        bounds: CGRect
    ) {
        guard isCurrent(surfaceIdentity) else {
            staleDrawingAttemptCount += 1
            return
        }
        prepareSurfaceForDrawing(surfaceIdentity.ordinal)
        guard activeGraph?.draw(
            surfaceIdentity: surfaceIdentity,
            in: context,
            bounds: bounds
        ) == true else {
            return
        }
        drawingAccessCount += 1
        lastDrawnSurfaceIdentity = surfaceIdentity
        lastDrawnDocumentRange = result?.viewportIndex.surfaces
            .first(where: { $0.surfaceOrdinal == surfaceIdentity.ordinal })?
            .frozenGeometry
            .map { $0.documentStartOffset..<$0.documentEndOffset }
    }

    private func selectableCharacterRange(
        around documentOffset: Int,
        in text: String
    ) -> Range<Int>? {
        let clampedOffset = min(max(documentOffset, 0), text.count)
        let effectiveOffset = clampedOffset == text.count ? max(text.count - 1, 0) : clampedOffset
        guard let index = text.index(text.startIndex, offsetBy: effectiveOffset, limitedBy: text.endIndex),
              index < text.endIndex,
              !text[index].isWhitespace else {
            return nil
        }

        let wordCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if text[index].unicodeScalars.allSatisfy({ wordCharacterSet.contains($0) }) {
            var start = index
            while start > text.startIndex {
                let previous = text.index(before: start)
                guard text[previous].unicodeScalars.allSatisfy({ wordCharacterSet.contains($0) }) else {
                    break
                }
                start = previous
            }
            var end = text.index(after: index)
            while end < text.endIndex,
                  text[end].unicodeScalars.allSatisfy({ wordCharacterSet.contains($0) }) {
                end = text.index(after: end)
            }
            return text.distance(from: text.startIndex, to: start)..<text.distance(from: text.startIndex, to: end)
        }

        let end = text.index(after: index)
        return effectiveOffset..<text.distance(from: text.startIndex, to: end)
    }
}
