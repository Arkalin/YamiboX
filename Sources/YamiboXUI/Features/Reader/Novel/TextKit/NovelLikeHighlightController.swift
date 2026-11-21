import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class NovelLikeHighlightController {
    private let registeredViews = NSHashTable<NovelTextViewportReferenceUIView>.weakObjects()
    private var workKey: ReadingWorkKey?
    private var likeStore: LikeStore?
    private var annotations: ReaderAnnotationService?
    private var onFailure: ((any Error) -> Void)?
    private var changeObserverTask: Task<Void, Never>?
    private var itemsByID: [String: LikeItem] = [:]
    private var rangesByItemID: [String: NovelTextSelectionRange] = [:]
    private struct DocumentKey: Equatable {
        let runtime: UUID
        let generation: UInt64
    }
    private struct IndexedRange {
        let itemID: String
        let range: NovelTextSelectionRange
        let maximumUpperBound: NovelDocumentUTF16Offset
    }
    private var cachedDocument: DocumentKey?
    private var indexedRanges: [IndexedRange] = []
    private var surfaceHighlights: [NovelReaderSurfaceIdentity: [ResolvedHighlight]] = [:]
    private var surfaceCacheOrder: [NovelReaderSurfaceIdentity] = []
    private static let maximumCachedSurfaces = 8
    private var configurationID = UUID()
    private var reloadRevision: UInt64 = 0

    deinit {
        changeObserverTask?.cancel()
    }

    func configure(
        workKey: ReadingWorkKey, likeStore: LikeStore,
        annotations: ReaderAnnotationService, onFailure: @escaping (any Error) -> Void
    ) {
        configurationID = UUID()
        reloadRevision &+= 1
        itemsByID.removeAll()
        invalidateRanges()
        self.workKey = workKey
        self.likeStore = likeStore
        self.annotations = annotations
        self.onFailure = onFailure
        changeObserverTask?.cancel()
        changeObserverTask = Task { @MainActor [weak self] in
            for await _ in likeStore.changes() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.reload()
            }
        }
        repaintRegisteredViews()
        Task { [weak self] in await self?.reload() }
    }

    func register(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.add(view)
        if let displayReference = view.displayReference {
            refreshIfNeeded(using: displayReference)
        }
        view.setNeedsDisplay()
    }

    func unregister(_ view: NovelTextViewportReferenceUIView) {
        registeredViews.remove(view)
    }

    struct ResolvedHighlight {
        let item: LikeItem
        let rects: [CGRect]
        let startRect: CGRect?
    }

    func highlights(
        for displayReference: NovelTextViewportDisplayReference
    ) -> [ResolvedHighlight] {
        guard !displayReference.isStale else { return [] }
        refreshIfNeeded(using: displayReference)
        let surface = displayReference.surfaceIdentity
        if let cached = surfaceHighlights[surface] { return cached }
        let surfaceRange = displayReference.surfaceDocumentRange
        var first = 0
        if let surfaceRange {
            var upper = indexedRanges.count
            while first < upper {
                let middle = first + (upper - first) / 2
                if indexedRanges[middle].maximumUpperBound <= surfaceRange.lowerBound { first = middle + 1 }
                else { upper = middle }
            }
        }
        var highlights: [ResolvedHighlight] = []
        for indexed in indexedRanges.dropFirst(first) {
            let range = indexed.range
            if let surfaceRange {
                if range.lowerBound >= surfaceRange.upperBound { break }
                guard range.upperBound > surfaceRange.lowerBound else { continue }
            }
            guard let item = itemsByID[indexed.itemID] else { continue }
            let rects = displayReference.selectionRects(for: range)
            guard !rects.isEmpty else { continue }
            highlights.append(ResolvedHighlight(
                item: item,
                rects: rects,
                startRect: item.hasNote
                    ? startRect(of: range, in: displayReference)
                    : nil
            ))
        }
        if surfaceCacheOrder.count == Self.maximumCachedSurfaces {
            surfaceHighlights.removeValue(forKey: surfaceCacheOrder.removeFirst())
        }
        surfaceCacheOrder.append(surface)
        surfaceHighlights[surface] = highlights
        return highlights
    }

    private func startRect(
        of range: NovelTextSelectionRange,
        in displayReference: NovelTextViewportDisplayReference
    ) -> CGRect? {
        guard let firstCharacter = NovelTextSelectionRange(
            generation: range.generation,
            lowerBound: range.lowerBound,
            upperBound: range.lowerBound + 1
        ) else {
            return nil
        }
        return displayReference.selectionRects(for: firstCharacter).first
    }

    func item(at point: CGPoint, in view: NovelTextViewportReferenceUIView) -> LikeItem? {
        guard let displayReference = view.displayReference else { return nil }
        for entry in highlights(for: displayReference)
            where entry.rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return entry.item
        }
        return nil
    }

    func item(at point: CGPoint, in window: UIWindow) -> LikeItem? {
        for view in registeredViews.allObjects where view.readerContains(windowPoint: point, in: window) {
            if let item = item(at: view.convert(point, from: window), in: view) { return item }
        }
        return nil
    }

    func item(id: String) -> LikeItem? { itemsByID[id] }

    func unionRect(for item: LikeItem, in view: NovelTextViewportReferenceUIView) -> CGRect? {
        guard let displayReference = view.displayReference else { return nil }
        let rects = highlights(for: displayReference)
            .first { $0.item.id == item.id }?
            .rects ?? []
        guard !rects.isEmpty else { return nil }
        return rects.reduce(CGRect.null) { $0.union($1) }
    }

    @discardableResult
    func remove(_ item: LikeItem) async -> Bool {
        guard let annotations else { return false }
        let expectedConfiguration = configurationID
        do {
            try await annotations.removeLikes([item])
            return configurationID == expectedConfiguration
        }
        catch {
            if configurationID == expectedConfiguration { onFailure?(error) }
            return false
        }
    }

    func restyle(_ item: LikeItem, to style: LikeStyle) {
        applyStyleOptimistically(itemID: item.id, style: style)
        ReaderHighlightStyleDefault.set(style)
        Task { await updateStyle(item, to: style) }
    }

    private func updateStyle(_ item: LikeItem, to style: LikeStyle) async {
        let expectedConfiguration = configurationID
        do { try await annotations?.updateStyle(id: item.id, style: style) }
        catch {
            guard configurationID == expectedConfiguration else { return }
            if itemsByID[item.id]?.style == style {
                applyStyleOptimistically(itemID: item.id, style: item.style)
            }
            onFailure?(error)
        }
    }

    func applyStyleOptimistically(itemID: String, style: LikeStyle) {
        guard itemsByID[itemID] != nil else { return }
        reloadRevision &+= 1
        itemsByID[itemID]?.style = style
        invalidateSurfaces()
        repaintRegisteredViews()
    }

    func applyCapturedItem(_ item: LikeItem) {
        guard item.kind == .text else { return }
        reloadRevision &+= 1
        itemsByID[item.id] = item
        invalidateRanges()
        repaintRegisteredViews()
    }

    private func refreshIfNeeded(using displayReference: NovelTextViewportDisplayReference) {
        guard let workKey, let runtime = displayReference.runtimeIdentity, !displayReference.isStale else { return }
        let key = DocumentKey(runtime: runtime, generation: displayReference.generation)
        guard cachedDocument != key else { return }
        invalidateRanges()
        cachedDocument = key
        rangesByItemID.removeAll()
        for item in itemsByID.values {
            guard case let .novelText(anchor) = item.anchor,
                  let range = displayReference.highlightRange(for: anchor, workKey: workKey) else { continue }
            rangesByItemID[item.id] = range
        }
        var maximumUpperBound: NovelDocumentUTF16Offset = 0
        indexedRanges = rangesByItemID.sorted {
            $0.value.lowerBound == $1.value.lowerBound
                ? $0.key < $1.key : $0.value.lowerBound < $1.value.lowerBound
        }.map { itemID, range in
            maximumUpperBound = max(maximumUpperBound, range.upperBound)
            return IndexedRange(itemID: itemID, range: range, maximumUpperBound: maximumUpperBound)
        }
        backfillExcerptContexts(using: displayReference)
    }

    private func backfillExcerptContexts(using displayReference: NovelTextViewportDisplayReference) {
        guard let likeStore else { return }
        var contexts: [String: (prefix: String?, suffix: String?)] = [:]
        for item in itemsByID.values where item.excerptPrefix == nil && item.excerptSuffix == nil {
            guard let range = rangesByItemID[item.id],
                  let surrounding = displayReference.surroundingText(for: range, radius: 80) else {
                continue
            }
            contexts[item.id] = NovelLikeExcerptContext.make(
                textBefore: surrounding.before,
                textAfter: surrounding.after
            )
        }
        guard !contexts.isEmpty else { return }
        Task { await likeStore.resolveExcerptContexts(contexts) }
    }

    private func reload() async {
        guard let workKey, let likeStore else { return }
        let expectedConfiguration = configurationID
        reloadRevision &+= 1
        let expectedRevision = reloadRevision
        let fetched: [LikeItem]
        do { fetched = try await likeStore.likes(for: workKey) }
        catch {
            guard configurationID == expectedConfiguration, reloadRevision == expectedRevision else { return }
            onFailure?(error)
            return
        }
        guard configurationID == expectedConfiguration, reloadRevision == expectedRevision else { return }
        itemsByID = Dictionary(fetched.filter { $0.kind == .text }.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        invalidateRanges()
        repaintRegisteredViews()
    }

    private func invalidateRanges() {
        cachedDocument = nil
        rangesByItemID.removeAll()
        indexedRanges.removeAll()
        invalidateSurfaces()
    }

    private func invalidateSurfaces() {
        surfaceHighlights.removeAll()
        surfaceCacheOrder.removeAll()
    }

    private func repaintRegisteredViews() {
        for view in registeredViews.allObjects {
            view.setNeedsDisplay()
        }
    }
}
#endif
