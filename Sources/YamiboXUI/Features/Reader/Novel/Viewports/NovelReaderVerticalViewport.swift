import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

private struct NovelReaderVerticalViewportDisplaySurface {
    let identity: NovelReaderSurfaceIdentity
    let surfaceIndex: Int
    let documentView: Int
    let chapterTitle: String?
    let presentationHeight: CGFloat?
    let blocks: [NovelReaderViewportDisplayBlock]
}

struct NovelReaderVerticalViewportScrollView: UIViewRepresentable {
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    let structureID: UUID?
    let surfaces: [NovelReaderSurface]
    let settings: NovelReaderAppearanceSettings
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let scrollRequest: NovelReaderVerticalScrollRequest?
    let displayReferenceProvider: @MainActor (NovelReaderSurfaceIdentity) -> NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let searchHighlightController: NovelReaderSearchHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let isChromeVisible: Bool
    let onVisibleSurfaceIdentitiesChange: ([NovelReaderSurfaceIdentity]) -> Void
    let onScrollRequestHandled: (NovelReaderVerticalScrollRequest) -> Void
    let onScrollViewReady: (UIScrollView) -> Void
    let onSurfaceFramesChange: ([Int: NovelReaderVerticalSurfaceFrameValue]) -> Void
    let onViewportSampleChange: (NovelReaderVerticalViewportSample?) -> Void
    let onViewportChange: () -> Void
    let onScrollSettled: () -> Void
    let onTap: () -> Void
    let onChromeVisibleImageTap: () -> Void
    let onImageTap: (URL, String?) -> Void
    let onImageLongPress: (NovelImageLikeAnchor, URL, String?) -> Void

    private var contentIdentity: NovelReaderVerticalViewportContentIdentity {
        NovelReaderVerticalViewportContentIdentity(
            structureID: structureID,
            settings: settings,
            refererURL: refererURL
        )
    }

    private var verticalLineSpacing: CGFloat {
        Self.verticalLineSpacing(for: settings)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = verticalLineSpacing
        layout.minimumInteritemSpacing = 0
        layout.estimatedItemSize = .zero

        let collectionView = NovelReaderVerticalViewportCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(NovelReaderVerticalViewportCell.self, forCellWithReuseIdentifier: NovelReaderVerticalViewportCell.reuseIdentifier)
        let coordinator = context.coordinator
        collectionView.onLayoutSubviews = { [weak coordinator, weak collectionView] in
            guard let coordinator, let collectionView else { return }
            // Layout can run inside the SwiftUI render commit; defer the
            // frame/viewport publishes out of the update transaction.
            coordinator.callbackScheduler.performViewUpdate {
                coordinator.publishLayout(from: collectionView)
            }
        }
        context.coordinator.tapGesture.cancelsTouchesInView = false
        context.coordinator.tapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(context.coordinator.tapGesture)
        context.coordinator.longPressGesture.minimumPressDuration = 0.45
        context.coordinator.longPressGesture.cancelsTouchesInView = false
        context.coordinator.longPressGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(context.coordinator.longPressGesture)
        onScrollViewReady(collectionView)
        selectionController?.configure(mode: .vertical)
        selectionController?.attachVerticalScrollView(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        selectionController?.configure(mode: .vertical)
        selectionController?.attachVerticalScrollView(collectionView)
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.updateLineSpacing(in: collectionView)
            context.coordinator.reloadDataIfNeeded(in: collectionView, contentIdentity: contentIdentity)
            context.coordinator.handle(scrollRequest, in: collectionView)
        }
    }

    private static func verticalLineSpacing(for settings: NovelReaderAppearanceSettings) -> CGFloat {
        max(CGFloat(6 * settings.lineHeightScale), 0)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NovelReaderVerticalViewportScrollView
        let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
        private var contentIdentity: NovelReaderVerticalViewportContentIdentity?
        private var imagePipeline: YamiboUIImagePipeline?
        private var handledScrollRequest: NovelReaderVerticalScrollRequest?
        private var lastPublishedSurfaceFrames: [Int: NovelReaderVerticalSurfaceFrameValue]?
        private var lastPublishedVisibleSurfaceIdentities: [NovelReaderSurfaceIdentity]?
        private var lastPublishedViewportSample: NovelReaderVerticalViewportSample?
        private var hasPublishedNilViewportSample = false
        private var isImmediateVisibleTextRedrawScheduled = false
        private var isDelayedVisibleTextRedrawScheduled = false
        lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        lazy var longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))

        init(parent: NovelReaderVerticalViewportScrollView) {
            self.parent = parent
            super.init()
        }

        fileprivate func updateLineSpacing(in collectionView: UICollectionView) {
            guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
                return
            }
            let lineSpacing = parent.verticalLineSpacing
            guard layout.minimumLineSpacing != lineSpacing else { return }
            layout.minimumLineSpacing = lineSpacing
            layout.invalidateLayout()
        }

        fileprivate func reloadDataIfNeeded(
            in collectionView: UICollectionView,
            contentIdentity nextContentIdentity: NovelReaderVerticalViewportContentIdentity
        ) {
            let contentIdentityChanged = contentIdentity != nextContentIdentity || imagePipeline !== parent.imagePipeline
            let insetsChanged = updateInsets(in: collectionView)
            guard contentIdentityChanged else {
                if insetsChanged {
                    publishLayout(from: collectionView)
                }
                return
            }
            contentIdentity = nextContentIdentity
            imagePipeline = parent.imagePipeline
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.reloadData()
            resetPublishedViewportCache()
            if collectionView.bounds.width > 0, collectionView.bounds.height > 0 {
                collectionView.layoutIfNeeded()
                publishLayout(from: collectionView)
            }
            scheduleVisibleTextRedraw(in: collectionView, includeDelayedPass: true)
        }

        @discardableResult
        private func updateInsets(in collectionView: UICollectionView) -> Bool {
            let contentInset = UIEdgeInsets(
                top: parent.topInset,
                left: 0,
                bottom: parent.bottomInset,
                right: 0
            )
            guard collectionView.contentInset != contentInset else { return false }
            let previousVisibleOffsetY = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            collectionView.contentInset = contentInset
            collectionView.scrollIndicatorInsets = contentInset
            let nextOffsetY = previousVisibleOffsetY - collectionView.adjustedContentInset.top
            if collectionView.contentOffset.y != nextOffsetY {
                collectionView.setContentOffset(
                    CGPoint(x: collectionView.contentOffset.x, y: nextOffsetY),
                    animated: false
                )
            }
            return true
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            verticalSurfaceCount
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: NovelReaderVerticalViewportCell.reuseIdentifier,
                for: indexPath
            )
            guard let cell = cell as? NovelReaderVerticalViewportCell else {
                return cell
            }
            guard let displaySurface = verticalDisplaySurface(for: indexPath.item) else {
                return cell
            }
            let displayReference = parent.displayReferenceProvider(displaySurface.identity)
            cell.configure(
                page: displaySurface,
                displayReference: displayReference,
                selectionController: parent.selectionController,
                likeHighlightController: parent.likeHighlightController,
                searchHighlightController: parent.searchHighlightController,
                likedImageAnchors: parent.likedImageAnchors,
                surface: verticalSurface(for: indexPath.item),
                textHeight: displaySurface.presentationHeight,
                settings: parent.settings,
                refererURL: parent.refererURL,
                offlineScope: parent.offlineScope,
                imagePipeline: parent.imagePipeline,
                contentWidth: max(verticalItemWidth(in: collectionView) - parent.settings.horizontalPadding * 2, 1),
                topPadding: displaySurface.surfaceIndex == 0 ? 16 : 0,
                onImageTap: parent.onImageTap
            )
            if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                cell.refreshLayout(for: attributes.size)
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let cell = cell as? NovelReaderVerticalViewportCell else { return }
            if let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                cell.refreshLayout(for: attributes.size)
            } else {
                cell.refreshLayoutForCurrentBounds(forceRedraw: true)
            }
            scheduleVisibleTextRedraw(in: collectionView, includeDelayedPass: false)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            CGSize(
                width: verticalItemWidth(in: collectionView),
                height: verticalItemHeight(for: indexPath.item, in: collectionView)
            )
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishFrames(from: scrollView)
            let onViewportChange = parent.onViewportChange
            callbackScheduler.publish {
                onViewportChange()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            publishScrollSettled(from: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            publishScrollSettled(from: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            publishScrollSettled(from: scrollView)
        }

        func publishLayout(from collectionView: UICollectionView) {
            publishFrames(from: collectionView)
            let onViewportChange = parent.onViewportChange
            callbackScheduler.publish {
                onViewportChange()
            }
        }

        func handle(_ request: NovelReaderVerticalScrollRequest?, in collectionView: UICollectionView) {
            guard let request else {
                handledScrollRequest = nil
                return
            }
            guard request.surfaceIndex >= 0, request.surfaceIndex < verticalSurfaceCount else {
                handledScrollRequest = nil
                return
            }
            guard collectionView.bounds.width > 0,
                  collectionView.bounds.height > 0,
                  collectionView.contentSize.height > 0 else {
                handledScrollRequest = nil
                return
            }
            guard handledScrollRequest != request else { return }
            handledScrollRequest = request
            collectionView.scrollToItem(
                at: IndexPath(item: request.surfaceIndex, section: 0),
                at: .top,
                animated: false
            )
            let didRestoreTextAnchor = restoreTextAnchorIfPossible(for: request, in: collectionView)
            guard request.textAnchor == nil || didRestoreTextAnchor else {
                handledScrollRequest = nil
                return
            }
            let onScrollRequestHandled = parent.onScrollRequestHandled
            callbackScheduler.publish {
                onScrollRequestHandled(request)
            }
            scheduleVisibleTextRedraw(in: collectionView, includeDelayedPass: true)
            publishScrollSettled(from: collectionView)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if let collectionView = recognizer.view as? UICollectionView {
                let location = recognizer.location(in: collectionView)
                if parent.selectionController?.hasSelection == true {
                    parent.selectionController?.clearSelection()
                    return
                }
                if let imageView = collectionView.firstDescendant(
                    ofType: NovelReaderVerticalViewportImageView.self,
                    containing: location
                ) {
                    let imageLocation = collectionView.convert(location, to: imageView)
                    handleImageTap(imageView, at: imageLocation)
                    return
                }
            }
            let onTap = parent.onTap
            callbackScheduler.publish {
                onTap()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view?.isDescendant(ofType: NovelReaderVerticalViewportImageView.self) == true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.view?.isDescendant(ofType: UIControl.self) != true
        }

        private func handleImageTap(_ imageView: NovelReaderVerticalViewportImageView, at location: CGPoint) {
            if parent.isChromeVisible {
                let onChromeVisibleImageTap = parent.onChromeVisibleImageTap
                callbackScheduler.publish {
                    onChromeVisibleImageTap()
                }
                return
            }

            guard let payload = imageView.imageTapPayloadIfHit(at: location) else { return }
            let onImageTap = parent.onImageTap
            callbackScheduler.publish {
                onImageTap(payload.url, payload.title)
            }
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let collectionView = recognizer.view as? UICollectionView else {
                return
            }
            let location = recognizer.location(in: collectionView)
            guard let imageView = collectionView.firstDescendant(
                ofType: NovelReaderVerticalViewportImageView.self,
                containing: location
            ), let payload = imageView.imageTapPayloadIfHit(
                at: collectionView.convert(location, to: imageView)
            ), let anchor = novelImageLikeAnchor(forImageURL: payload.url, in: parent.surfaces) else {
                return
            }
            let onImageLongPress = parent.onImageLongPress
            callbackScheduler.publish {
                onImageLongPress(anchor, payload.url, payload.title)
            }
        }

        private func publishFrames(from scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            let frames = collectionView.indexPathsForVisibleItems.reduce(into: [Int: NovelReaderVerticalSurfaceFrameValue]()) { result, indexPath in
                guard let surface = verticalSurface(for: indexPath.item),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                    return
                }
                let visibleFrame = attributes.frame.offsetBy(
                    dx: -collectionView.contentOffset.x,
                    dy: -collectionView.contentOffset.y
                )
                result[surface.presentationIndex] = NovelReaderVerticalSurfaceFrameValue(
                    documentView: surface.documentView,
                    frame: visibleFrame
                )
            }
            let onSurfaceFramesChange = parent.onSurfaceFramesChange
            if lastPublishedSurfaceFrames != frames {
                lastPublishedSurfaceFrames = frames
                callbackScheduler.publish {
                    onSurfaceFramesChange(frames)
                }
            }
            let visibleSurfaceIdentities = collectionView.indexPathsForVisibleItems
                .sorted { $0.item < $1.item }
                .compactMap { verticalSurface(for: $0.item)?.identity }
            let onVisibleSurfaceIdentitiesChange = parent.onVisibleSurfaceIdentitiesChange
            if lastPublishedVisibleSurfaceIdentities != visibleSurfaceIdentities {
                lastPublishedVisibleSurfaceIdentities = visibleSurfaceIdentities
                callbackScheduler.publish {
                    onVisibleSurfaceIdentitiesChange(visibleSurfaceIdentities)
                }
            }

            let referenceLineY = NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: scrollView.bounds)
            let sample = viewportSample(in: collectionView, frames: frames, referenceLineY: referenceLineY)
            let onViewportSampleChange = parent.onViewportSampleChange
            if shouldPublishViewportSample(sample) {
                lastPublishedViewportSample = sample
                hasPublishedNilViewportSample = sample == nil
                callbackScheduler.publish {
                    onViewportSampleChange(sample)
                }
            }
        }

        private func viewportSample(
            in collectionView: UICollectionView,
            frames: [Int: NovelReaderVerticalSurfaceFrameValue],
            referenceLineY: CGFloat
        ) -> NovelReaderVerticalViewportSample? {
            // Select the surface before asking TextKit for a sample so nearby
            // text cannot take the reading position away from an image.
            guard let index = NovelReaderVerticalPositioning.nearestSurfaceIndex(
                to: referenceLineY, frames: frames.mapValues(\.frame)
            ), let surface = verticalSurface(for: index) else { return nil }
            if surface.kind == .externalBlock {
                return .image(surface.identity)
            }
            guard let frame = frames[index]?.frame,
                  let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? NovelReaderVerticalViewportCell,
                  let sample = cell.textViewportSample(referenceLineY: referenceLineY, surfaceFrame: frame) else {
                return nil
            }
            return .text(sample)
        }

        private func scheduleVisibleTextRedraw(in collectionView: UICollectionView, includeDelayedPass: Bool) {
            if !isImmediateVisibleTextRedrawScheduled {
                isImmediateVisibleTextRedrawScheduled = true
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    self?.isImmediateVisibleTextRedrawScheduled = false
                    self?.redrawVisibleText(in: collectionView)
                }
            }
            guard includeDelayedPass, !isDelayedVisibleTextRedrawScheduled else { return }
            isDelayedVisibleTextRedrawScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak collectionView] in
                self?.isDelayedVisibleTextRedrawScheduled = false
                self?.redrawVisibleText(in: collectionView)
            }
        }

        private func redrawVisibleText(in collectionView: UICollectionView?) {
            collectionView?.visibleCells.forEach { cell in
                guard let cell = cell as? NovelReaderVerticalViewportCell else { return }
                cell.refreshLayoutForCurrentBounds(forceRedraw: true)
            }
        }

        private func resetPublishedViewportCache() {
            lastPublishedSurfaceFrames = nil
            lastPublishedVisibleSurfaceIdentities = nil
            lastPublishedViewportSample = nil
            hasPublishedNilViewportSample = false
        }

        private func shouldPublishViewportSample(_ sample: NovelReaderVerticalViewportSample?) -> Bool {
            guard let sample else {
                return !hasPublishedNilViewportSample || lastPublishedViewportSample != nil
            }
            return lastPublishedViewportSample != sample
        }

        private func publishScrollSettled(from scrollView: UIScrollView) {
            publishFrames(from: scrollView)
            let onScrollSettled = parent.onScrollSettled
            callbackScheduler.publish {
                onScrollSettled()
            }
        }

        private func verticalItemWidth(in collectionView: UICollectionView) -> CGFloat {
            max(
                collectionView.bounds.width
                    - collectionView.adjustedContentInset.left
                    - collectionView.adjustedContentInset.right,
                1
            )
        }

        private func verticalItemHeight(for item: Int, in collectionView: UICollectionView) -> CGFloat {
            guard let displaySurface = verticalDisplaySurface(for: item) else {
                return max(collectionView.bounds.height, 1)
            }
            let topPadding = displaySurface.surfaceIndex == 0 ? CGFloat(16) : 0
            if let presentationHeight = displaySurface.presentationHeight {
                return max(ceil(presentationHeight + topPadding), 1)
            }
            let blockHeights = displaySurface.blocks.map { block -> CGFloat in
                switch block {
                case .text:
                    return max(collectionView.bounds.height, 1)
                case .image:
                    return max(collectionView.bounds.height, 160)
                case .footer:
                    return 44
                }
            }
            let contentHeight = blockHeights.reduce(CGFloat.zero, +)
            let spacingHeight = CGFloat(max(displaySurface.blocks.count - 1, 0)) * 14
            return max(ceil(contentHeight + spacingHeight + topPadding), 1)
        }

        private var verticalSurfaceCount: Int {
            parent.surfaces.count
        }

        private func verticalSurface(for item: Int) -> NovelReaderSurface? {
            guard parent.surfaces.indices.contains(item) else { return nil }
            return parent.surfaces[item]
        }

        private func verticalDisplaySurface(for item: Int) -> NovelReaderVerticalViewportDisplaySurface? {
            guard let surface = verticalSurface(for: item) else { return nil }
            return NovelReaderVerticalViewportDisplaySurface(
                identity: surface.identity,
                surfaceIndex: surface.presentationIndex,
                documentView: surface.documentView,
                chapterTitle: surface.chapterTitle,
                presentationHeight: surface.presentationSize.height > 0 ? surface.presentationSize.height : nil,
                blocks: NovelReaderViewportSurfaceContent.viewportBlocks(
                    surface: surface
                )
            )
        }

        private func restoreTextAnchorIfPossible(
            for request: NovelReaderVerticalScrollRequest,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let textAnchor = request.textAnchor,
                  request.surfaceIndex >= 0,
                  request.surfaceIndex < verticalSurfaceCount else {
                return request.textAnchor == nil
            }

            let targetIndexPath = IndexPath(item: request.surfaceIndex, section: 0)
            let visibleItems = collectionView.indexPathsForVisibleItems.map(\.item)
            let nearbyItems = ((request.surfaceIndex - 2)...(request.surfaceIndex + 2))
                .filter { $0 >= 0 && $0 < verticalSurfaceCount }
            var seenItems = Set<Int>()
            let candidateItems = ([request.surfaceIndex] + visibleItems + nearbyItems)
                .filter { seenItems.insert($0).inserted }
                .sorted { lhs, rhs in
                    abs(lhs - request.surfaceIndex) < abs(rhs - request.surfaceIndex)
                }

            for item in candidateItems {
                let indexPath = IndexPath(item: item, section: 0)
                guard let cell = collectionView.cellForItem(at: indexPath) as? NovelReaderVerticalViewportCell,
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                    continue
                }
                let visibleFrame = attributes.frame.offsetBy(
                    dx: -collectionView.contentOffset.x,
                    dy: -collectionView.contentOffset.y
                )
                guard let anchorY = cell.textViewportAnchorY(
                    for: textAnchor,
                    surfaceFrame: visibleFrame
                ) else {
                    continue
                }
                applyTextAnchorRestore(
                    anchorY: anchorY,
                    request: request,
                    collectionView: collectionView,
                    restoredItem: item,
                    visibleFrame: visibleFrame
                )
                return true
            }

            guard collectionView.cellForItem(at: targetIndexPath) is NovelReaderVerticalViewportCell,
                  let targetAttributes = collectionView.layoutAttributesForItem(at: targetIndexPath) else {
                return false
            }
            let targetFrame = targetAttributes.frame.offsetBy(
                dx: -collectionView.contentOffset.x,
                dy: -collectionView.contentOffset.y
            )
            applyProgressFallbackRestore(
                request: request,
                collectionView: collectionView,
                visibleFrame: targetFrame
            )
            return true
        }

        private func applyTextAnchorRestore(
            anchorY: CGFloat,
            request: NovelReaderVerticalScrollRequest,
            collectionView: UICollectionView,
            restoredItem: Int,
            visibleFrame: CGRect
        ) {
            let referenceLineY = NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: collectionView.bounds)
            let desiredY = collectionView.contentOffset.y + anchorY - referenceLineY
            let minOffsetY = -collectionView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
            )
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: min(max(desiredY, minOffsetY), maxOffsetY)),
                animated: false
            )
        }

        private func applyProgressFallbackRestore(
            request: NovelReaderVerticalScrollRequest,
            collectionView: UICollectionView,
            visibleFrame: CGRect
        ) {
            let referenceLineY = NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: collectionView.bounds)
            let desiredY = collectionView.contentOffset.y
                + visibleFrame.minY
                + visibleFrame.height * min(max(request.intraSurfaceProgress, 0), 1)
                - referenceLineY
            let minOffsetY = -collectionView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
            )
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: min(max(desiredY, minOffsetY), maxOffsetY)),
                animated: false
            )
        }
    }
}

private final class NovelReaderVerticalViewportCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

private final class NovelReaderVerticalViewportCell: UICollectionViewCell {
    static let reuseIdentifier = "ReaderVerticalViewportScrollCell"

    private struct BlockView {
        let view: UIView
        let height: CGFloat
        let displayReference: NovelTextViewportDisplayReference?
    }

    private var blockViews: [BlockView] = []
    private var currentPage: NovelReaderVerticalViewportDisplaySurface?
    private var currentSettings = NovelReaderAppearanceSettings()
    private var currentRefererURL: URL?
    private var currentOfflineScope: YamiboImageOfflineScope?
    private var currentImagePipeline: YamiboUIImagePipeline?
    private var currentContentWidth: CGFloat = 0
    private var currentTopPadding: CGFloat = 0
    private var currentDisplayReference: NovelTextViewportDisplayReference?
    private weak var currentSelectionController: NovelTextSelectionController?
    private weak var currentLikeHighlightController: NovelLikeHighlightController?
    private weak var currentSearchHighlightController: NovelReaderSearchHighlightController?
    private var currentLikedImageAnchors: Set<NovelImageLikeAnchor> = []
    private var currentSurface: NovelReaderSurface?
    private var currentTextHeight: CGFloat?
    private var currentOnImageTap: (URL, String?) -> Void = { _, _ in }
    private var lastAppliedLayoutSize = CGSize.zero
    private var preferredLayoutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: NovelReaderVerticalViewportCell, previousTraitCollection) in
            guard previousTraitCollection.userInterfaceStyle != cell.traitCollection.userInterfaceStyle else { return }
            cell.reconfigureForCurrentTraitCollection()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentPage = nil
        currentImagePipeline = nil
        currentDisplayReference = nil
        currentSelectionController = nil
        currentLikeHighlightController = nil
        currentSearchHighlightController = nil
        currentLikedImageAnchors = []
        currentSurface = nil
        currentTextHeight = nil
        currentOnImageTap = { _, _ in }
        lastAppliedLayoutSize = .zero
        preferredLayoutSize = .zero
        removeBlockSubviews()
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        let previousSize = lastAppliedLayoutSize
        super.apply(layoutAttributes)
        let nextSize = effectiveLayoutSize(for: layoutAttributes.size)
        guard previousSize != nextSize else { return }
        lastAppliedLayoutSize = nextSize
        applyContentViewFrame(for: nextSize)
        refreshLayoutForCurrentBounds()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyContentViewFrame(for: effectiveLayoutSize(for: bounds.size))
        layoutBlockSubviews()
    }

    private func reconfigureForCurrentTraitCollection() {
        guard let currentPage,
              let currentRefererURL else {
            return
        }
        configure(
            page: currentPage,
            displayReference: currentDisplayReference,
            selectionController: currentSelectionController,
            likeHighlightController: currentLikeHighlightController,
            searchHighlightController: currentSearchHighlightController,
            likedImageAnchors: currentLikedImageAnchors,
            surface: currentSurface,
            textHeight: currentTextHeight,
            settings: currentSettings,
            refererURL: currentRefererURL,
            offlineScope: currentOfflineScope,
            imagePipeline: currentImagePipeline,
            contentWidth: currentContentWidth,
            topPadding: currentTopPadding,
            onImageTap: currentOnImageTap
        )
    }

    func configure(
        page: NovelReaderVerticalViewportDisplaySurface,
        displayReference: NovelTextViewportDisplayReference?,
        selectionController: NovelTextSelectionController?,
        likeHighlightController: NovelLikeHighlightController?,
        searchHighlightController: NovelReaderSearchHighlightController?,
        likedImageAnchors: Set<NovelImageLikeAnchor>,
        surface: NovelReaderSurface?,
        textHeight: CGFloat?,
        settings: NovelReaderAppearanceSettings,
        refererURL: URL,
        offlineScope: YamiboImageOfflineScope?,
        imagePipeline: YamiboUIImagePipeline?,
        contentWidth: CGFloat,
        topPadding: CGFloat,
        onImageTap: @escaping (URL, String?) -> Void
    ) {
        currentPage = page
        currentDisplayReference = displayReference
        currentSelectionController = selectionController
        currentLikeHighlightController = likeHighlightController
        currentSearchHighlightController = searchHighlightController
        currentLikedImageAnchors = likedImageAnchors
        currentSurface = surface
        currentTextHeight = textHeight
        currentSettings = settings
        currentRefererURL = refererURL
        currentOfflineScope = offlineScope
        currentImagePipeline = imagePipeline
        currentContentWidth = contentWidth
        currentTopPadding = topPadding
        currentOnImageTap = onImageTap

        removeBlockSubviews()

        for (blockIndex, block) in page.blocks.enumerated() {
            let blockView = makeBlockView(
                for: block,
                blockIndex: blockIndex,
                page: page,
                contentWidth: contentWidth,
                refererURL: refererURL,
                offlineScope: offlineScope,
                imagePipeline: imagePipeline,
                displayReference: displayReference,
                selectionController: selectionController,
                likeHighlightController: likeHighlightController,
                searchHighlightController: searchHighlightController,
                isLiked: {
                    guard case let .image(url) = block else { return false }
                    return isNovelImageLiked(url, surface: surface, likedAnchors: likedImageAnchors)
                }(),
                textHeight: textHeight,
                onImageTap: onImageTap
            )
            blockViews.append(blockView)
            contentView.addSubview(blockView.view)
        }
        let blockHeight = blockViews.reduce(CGFloat.zero) { $0 + $1.height }
        let spacingHeight = CGFloat(max(blockViews.count - 1, 0)) * 14
        preferredLayoutSize = CGSize(
            width: max(contentWidth + settings.horizontalPadding * 2, bounds.width, 1),
            height: max(ceil(blockHeight + spacingHeight + topPadding), 1)
        )
        refreshLayout(for: preferredLayoutSize)
    }

    func textViewportSample(
        referenceLineY: CGFloat,
        surfaceFrame: CGRect
    ) -> NovelTextViewportSample? {
        let contentY = referenceLineY - surfaceFrame.minY
        let candidates = blockViews.compactMap { block -> (distance: CGFloat, sample: NovelTextViewportSample)? in
            guard let displayReference = block.displayReference else {
                return nil
            }
            let referencePoint = CGPoint(x: block.view.bounds.midX, y: contentY - block.view.frame.minY)
            guard let sample = displayReference.viewportSample(referencePoint: referencePoint) else {
                return nil
            }
            return (NovelReaderVerticalPositioning.pageDistance(from: contentY, to: block.view.frame), sample)
        }
        return candidates.min { $0.distance < $1.distance }?.sample
    }

    func textViewportAnchorY(
        for anchor: NovelReaderVerticalTextAnchor,
        surfaceFrame: CGRect
    ) -> CGFloat? {
        for block in blockViews {
            guard let displayReference = block.displayReference,
                  let referenceY = displayReference.referenceY(for: anchor.position) else {
                continue
            }
            return surfaceFrame.minY + block.view.frame.minY + referenceY
        }
        return nil
    }

    func setNeedsDisplayForTextBlocks() {
        for block in blockViews where block.displayReference != nil {
            block.view.setNeedsDisplay()
        }
    }

    func refreshLayoutForCurrentBounds(forceRedraw: Bool = false) {
        let didChangeLayout = layoutBlockSubviews()
        if forceRedraw || didChangeLayout {
            setNeedsDisplayForTextBlocks()
        }
    }

    func refreshLayout(for layoutSize: CGSize) {
        let nextSize = effectiveLayoutSize(for: layoutSize)
        lastAppliedLayoutSize = nextSize
        applyContentViewFrame(for: nextSize)
        refreshLayoutForCurrentBounds()
    }

    private func configureViewHierarchy() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = true
        contentView.clipsToBounds = true
    }

    private func makeBlockView(
        for block: NovelReaderViewportDisplayBlock,
        blockIndex: Int,
        page: NovelReaderVerticalViewportDisplaySurface,
        contentWidth: CGFloat,
        refererURL: URL,
        offlineScope: YamiboImageOfflineScope?,
        imagePipeline: YamiboUIImagePipeline?,
        displayReference: NovelTextViewportDisplayReference?,
        selectionController: NovelTextSelectionController?,
        likeHighlightController: NovelLikeHighlightController?,
        searchHighlightController: NovelReaderSearchHighlightController?,
        isLiked: Bool,
        textHeight: CGFloat?,
        onImageTap: @escaping (URL, String?) -> Void
    ) -> BlockView {
        switch block {
        case .text:
            return makeTextBlockView(
                contentWidth: contentWidth,
                displayReference: displayReference,
                selectionController: selectionController,
                likeHighlightController: likeHighlightController,
                searchHighlightController: searchHighlightController,
                textHeight: textHeight
            )
        case let .image(url):
            return makeImageBlockView(
                url: url,
                refererURL: refererURL,
                offlineScope: offlineScope,
                imagePipeline: imagePipeline,
                preferredHeight: textHeight,
                title: page.chapterTitle,
                isLiked: isLiked,
                onImageTap: onImageTap
            )
        case let .footer(text):
            return makeFooterBlockView(text)
        }
    }

    private func makeTextBlockView(
        contentWidth: CGFloat,
        displayReference: NovelTextViewportDisplayReference?,
        selectionController: NovelTextSelectionController?,
        likeHighlightController: NovelLikeHighlightController?,
        searchHighlightController: NovelReaderSearchHighlightController?,
        textHeight: CGFloat?
    ) -> BlockView {
        let surface = NovelTextViewportReferenceUIView()
        surface.displayReference = displayReference
        surface.selectionController = selectionController
        surface.likeHighlightController = likeHighlightController
        surface.searchHighlightController = searchHighlightController
        return BlockView(
            view: surface,
            height: max(textHeight ?? bounds.height, 1),
            displayReference: displayReference
        )
    }

    private func makeImageBlockView(
        url: URL,
        refererURL: URL,
        offlineScope: YamiboImageOfflineScope?,
        imagePipeline: YamiboUIImagePipeline?,
        preferredHeight: CGFloat?,
        title: String?,
        isLiked: Bool,
        onImageTap: @escaping (URL, String?) -> Void
    ) -> BlockView {
        let height = max(preferredHeight ?? bounds.height, 1)
        let imageView = NovelReaderVerticalViewportImageView(pipeline: imagePipeline)
        imageView.configure(
            source: YamiboImageSource(url: url, refererPageURL: refererURL, offlineScope: offlineScope),
            title: title,
            isLiked: isLiked,
            onTap: onImageTap
        )
        return BlockView(view: imageView, height: height, displayReference: nil)
    }

    private func makeFooterBlockView(_ text: String) -> BlockView {
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .caption1)
        label.numberOfLines = 0
        return BlockView(view: label, height: 44, displayReference: nil)
    }

    @discardableResult
    private func layoutBlockSubviews() -> Bool {
        let x = currentSettings.horizontalPadding
        let width = max(contentView.bounds.width - currentSettings.horizontalPadding * 2, currentContentWidth, 1)
        var y = currentTopPadding
        var didChangeLayout = false
        for blockView in blockViews {
            let height = max(ceil(blockView.height), 1)
            let frame = CGRect(x: x, y: y, width: width, height: height)
            if blockView.view.frame != frame {
                blockView.view.frame = frame
                didChangeLayout = true
            }
            y += height + 14
        }
        return didChangeLayout
    }

    private func effectiveLayoutSize(for layoutSize: CGSize) -> CGSize {
        guard preferredLayoutSize.width > 0, preferredLayoutSize.height > 0 else {
            return layoutSize
        }
        return CGSize(
            width: max(layoutSize.width, preferredLayoutSize.width, 1),
            height: preferredLayoutSize.height
        )
    }

    private func applyContentViewFrame(for layoutSize: CGSize) {
        guard layoutSize.width > 0, layoutSize.height > 0 else { return }
        let contentFrame = CGRect(origin: .zero, size: layoutSize)
        if contentView.frame != contentFrame {
            contentView.frame = contentFrame
        }
    }

    private func removeBlockSubviews() {
        for blockView in blockViews {
            if let textView = blockView.view as? NovelTextViewportReferenceUIView {
                textView.selectionController = nil
                textView.likeHighlightController = nil
                textView.searchHighlightController = nil
            }
            blockView.view.removeFromSuperview()
        }
        blockViews.removeAll()
    }
}

final class NovelReaderVerticalViewportImageView: UIView {
    private var pipeline: YamiboUIImagePipeline?
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let detailsButton = UIButton(type: .system)
    private weak var presentedDetailsController: UIViewController?
    private var failureDetails: LoadFailureDetails? {
        didSet {
            guard oldValue != failureDetails else { return }
            presentedDetailsController?.dismiss(animated: true)
            presentedDetailsController = nil
        }
    }
    private let likedBadgeView: UIImageView = {
        let badge = UIImageView(image: UIImage(systemName: "heart.fill"))
        badge.tintColor = .systemPink
        badge.contentMode = .scaleAspectFit
        badge.isHidden = true
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.35
        badge.layer.shadowRadius = 2
        badge.layer.shadowOffset = CGSize(width: 0, height: 1)
        return badge
    }()
    private var task: Task<Void, Never>?
    private var url: URL?
    private var title: String?
    private var sourceIdentity: YamiboImageSource?

    init(frame: CGRect = .zero, pipeline: YamiboUIImagePipeline?) {
        self.pipeline = pipeline
        super.init(frame: frame)
        configureViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        task?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)

        let badgeSize: CGFloat = 22
        let badgeInset: CGFloat = 8
        likedBadgeView.frame = CGRect(
            x: bounds.maxX - badgeSize - badgeInset,
            y: bounds.minY + badgeInset,
            width: badgeSize,
            height: badgeSize
        )

        let horizontalInset: CGFloat = bounds.width >= 24 ? 12 : 0
        let availableWidth = max(bounds.width - horizontalInset * 2, 0)
        let labelSize = failureLabel.sizeThatFits(
            CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let labelWidth = min(labelSize.width, availableWidth)
        let buttonSize = retryButton.sizeThatFits(CGSize(width: availableWidth, height: bounds.height))
        let detailsSize = detailsButton.sizeThatFits(CGSize(width: availableWidth, height: bounds.height))
        let buttonWidth = min(max(buttonSize.width, detailsSize.width, 44), availableWidth)
        let buttonHeight = min(max(buttonSize.height, detailsSize.height, 44), max(bounds.height / 2, 0))
        let spacing = min(8, max(bounds.height - buttonHeight * 2, 0) / 2)
        let labelHeight = min(labelSize.height, max(bounds.height - buttonHeight * 2 - spacing * 2, 0))
        let contentHeight = labelHeight + spacing * 2 + buttonHeight * 2
        failureLabel.frame = CGRect(
            x: bounds.midX - labelWidth / 2,
            y: bounds.midY - contentHeight / 2,
            width: labelWidth,
            height: labelHeight
        )
        retryButton.frame = CGRect(
            x: bounds.midX - buttonWidth / 2,
            y: failureLabel.frame.maxY + spacing,
            width: buttonWidth,
            height: buttonHeight
        )
        detailsButton.frame = CGRect(
            x: bounds.midX - buttonWidth / 2,
            y: retryButton.frame.maxY + spacing,
            width: buttonWidth,
            height: buttonHeight
        )
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let image = imageView.image else {
            return !activityIndicator.isHidden || !failureLabel.isHidden
        }
        return ImageContentGeometry.containsAspectFitImagePoint(
            point,
            imageSize: image.size,
            containerSize: bounds.size
        )
    }

    func configure(
        source: YamiboImageSource,
        title: String?,
        isLiked: Bool,
        onTap: @escaping (URL, String?) -> Void
    ) {
        self.url = source.url
        self.title = title
        likedBadgeView.isHidden = !isLiked
        guard sourceIdentity != source else { return }
        sourceIdentity = source
        load(source: source)
    }

    func updatePipeline(_ pipeline: YamiboUIImagePipeline?) {
        guard self.pipeline !== pipeline else { return }
        self.pipeline = pipeline
        if let sourceIdentity { load(source: sourceIdentity) }
    }

    private func load(source: YamiboImageSource) {
        task?.cancel()
        task = nil
        imageView.image = nil
        failureLabel.isHidden = true
        retryButton.isHidden = true
        detailsButton.isHidden = true
        failureDetails = nil
        guard let pipeline else {
            activityIndicator.stopAnimating()
            return
        }
        if let cachedImage = pipeline.cachedImage(for: source) {
            show(image: cachedImage)
            return
        }
        activityIndicator.startAnimating()
        task = Task { [weak self] in
            do {
                let image = try await pipeline.image(for: source)
                guard !Task.isCancelled else { return }
                self?.show(image: image)
            } catch {
                guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error),
                      self?.sourceIdentity == source else { return }
                self?.showFailure(error: error, source: source)
            }
        }
    }

    private func configureViewHierarchy() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        addSubview(activityIndicator)

        failureLabel.text = L10n.string("image.load_failed")
        failureLabel.textColor = .secondaryLabel
        failureLabel.font = .preferredFont(forTextStyle: .caption1)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        failureLabel.isHidden = true
        addSubview(failureLabel)

        var retryConfiguration = UIButton.Configuration.plain()
        retryConfiguration.title = L10n.string("common.retry")
        retryConfiguration.image = UIImage(systemName: "arrow.clockwise")
        retryConfiguration.imagePadding = 6
        retryButton.configuration = retryConfiguration
        retryButton.accessibilityIdentifier = "novel-inline-image-retry"
        retryButton.isHidden = true
        detailsButton.isHidden = true
        failureDetails = nil
        retryButton.addTarget(self, action: #selector(retryImageLoad), for: .touchUpInside)
        addSubview(retryButton)
        detailsButton.setTitle(L10n.string("load_failure.details"), for: .normal)
        detailsButton.accessibilityIdentifier = "load-failure-details"
        detailsButton.addTarget(self, action: #selector(showDetails), for: .touchUpInside)
        addSubview(detailsButton)

        addSubview(likedBadgeView)
    }

    @objc private func showDetails() {
        guard let failureDetails, !detailsButton.isHidden else { return }
        if let controller = LoadFailureDetailsPresenter.present(failureDetails, from: self) {
            presentedDetailsController = controller
        }
    }

    @objc private func retryImageLoad() {
        guard !retryButton.isHidden, let source = sourceIdentity else { return }
        load(source: source)
    }

    func imageTapPayloadIfHit(at point: CGPoint) -> (url: URL, title: String?)? {
        guard let url,
              let image = imageView.image,
              ImageContentGeometry.containsAspectFitImagePoint(
                  point,
                  imageSize: image.size,
                  containerSize: bounds.size
              ) else {
            return nil
        }
        return (url, title)
    }

    @MainActor
    private func show(image: UIImage) {
        activityIndicator.stopAnimating()
        failureLabel.isHidden = true
        retryButton.isHidden = true
        detailsButton.isHidden = true
        failureDetails = nil
        imageView.image = image
    }

    @MainActor
    private func showFailure(error: any Error, source: YamiboImageSource) {
        activityIndicator.stopAnimating()
        failureLabel.isHidden = false
        retryButton.isHidden = false
        detailsButton.isHidden = false
        failureDetails = LoadFailureDetails(error: error, requestContext: source.url.absoluteString)
        imageView.image = nil
        setNeedsLayout()
    }
}

struct NovelReaderInlineViewportImage: UIViewRepresentable {
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    let url: URL
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let title: String?
    let isLiked: Bool
    let onTap: (URL, String?) -> Void

    init(
        url: URL,
        refererURL: URL,
        offlineScope: YamiboImageOfflineScope?,
        title: String?,
        isLiked: Bool = false,
        onTap: @escaping (URL, String?) -> Void
    ) {
        self.url = url
        self.refererURL = refererURL
        self.offlineScope = offlineScope
        self.title = title
        self.isLiked = isLiked
        self.onTap = onTap
    }

    func makeUIView(context: Context) -> NovelReaderVerticalViewportImageView {
        NovelReaderVerticalViewportImageView(pipeline: imagePipeline)
    }

    func updateUIView(_ uiView: NovelReaderVerticalViewportImageView, context: Context) {
        uiView.updatePipeline(imagePipeline)
        uiView.configure(
            source: YamiboImageSource(url: url, refererPageURL: refererURL, offlineScope: offlineScope),
            title: title,
            isLiked: isLiked,
            onTap: onTap
        )
    }
}

extension UIView {
    func isDescendant<T: UIView>(ofType type: T.Type) -> Bool {
        if self is T {
            return true
        }
        return superview?.isDescendant(ofType: type) ?? false
    }

    func firstDescendant<T: UIView>(
        ofType type: T.Type,
        containing point: CGPoint,
        event: UIEvent? = nil
    ) -> T? {
        for subview in subviews.reversed() {
            let subviewPoint = convert(point, to: subview)
            if let typedSubview = subview as? T,
               typedSubview.point(inside: subviewPoint, with: event) {
                return typedSubview
            }
            if let match = subview.firstDescendant(
                ofType: type,
                containing: subviewPoint,
                event: event
            ) {
                return match
            }
        }
        return nil
    }
}

private struct NovelReaderVerticalViewportContentIdentity: Hashable {
    var structureID: UUID?
    var settings: NovelReaderAppearanceSettings
    var refererURL: URL
}
#endif
