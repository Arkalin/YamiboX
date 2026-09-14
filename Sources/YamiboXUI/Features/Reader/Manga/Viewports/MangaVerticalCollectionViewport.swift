import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaVerticalCollectionViewport: UIViewRepresentable {
    let pages: [MangaReaderPageProjection]
    let currentPageIndex: Int?
    let viewportPlacement: MangaNovelReaderViewportPlacement?
    let controlScrollStep: ReaderControlScrollStepRequest?
    let imageLoader: MangaReaderPageImageLoader
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let likedPageIDs: Set<String>
    let onCurrentPageChange: (Int) -> Void
    let onControlScrollEdgeReached: (ReaderControlScrollDirection) -> Void
    var onVerticalBoundaryPull: (ReaderPageBoundary) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MangaVerticalNativeViewport {
        makeViewportView(coordinator: context.coordinator)
    }

    func makeViewportView(coordinator: Coordinator) -> MangaVerticalNativeViewport {
        let view = MangaVerticalNativeViewport()
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MangaVerticalNativeViewport, context: Context) {
        context.coordinator.parent = self
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.updateContentIfNeeded(in: view)
        }
    }

    static func dismantleUIView(_ view: MangaVerticalNativeViewport, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: MangaVerticalCollectionViewport
        let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
        private(set) weak var viewport: MangaVerticalNativeViewport?
        private(set) var logicalLayout = MangaVerticalCollectionZoomLayout()
        private(set) var layoutRevision = 0
        private var contentIdentity: [String] = []
        private var heightToWidthRatios: [String: CGFloat] = [:]
        private var pendingRatios: [String: CGFloat] = [:]
        private var ratioUpdateTask: Task<Void, Never>?
        private var prefetchImageLoader: MangaReaderPageImageLoader
        private var imagePrefetchCoordinator: ReaderImagePrefetchCoordinator
        private var lastPrefetchSources: [YamiboImageSource] = []
        private var isDismantled = false
        private var isUpdatingLayout = false
        private var lastAppliedLikedPageIDs: Set<String> = []
        private var pendingInitialPageIndex: Int?
        private var lastAppliedPlacementRevision: Int?
        private var lastAppliedControlScrollRevision: Int?
        private var pendingControlScrollTarget: (y: CGFloat, timestamp: TimeInterval)?
        private var lastReportedGlobalIndex: Int?
        private var pendingReportedGlobalIndex: Int?
        private var currentPagePublishDisplayLink: CADisplayLink?
        private var pendingBoundaryPull: ReaderPageBoundary?
        private var panIncludedPinch = false
        private let currentTime: () -> CFTimeInterval
        private var lastScrollMotionTime: CFTimeInterval?
        private static let chromeToggleMotionSuppressionInterval: CFTimeInterval = 0.35
        var verticalZoomScale: CGFloat { viewport?.normalizedZoomFactor ?? 1 }
        var pinchGesture: UIPinchGestureRecognizer { viewport!.pinchGestureRecognizer! }
        lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        lazy var doubleTapGesture: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            recognizer.numberOfTapsRequired = 2
            return recognizer
        }()

        init(parent: MangaVerticalCollectionViewport, currentTime: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
            self.parent = parent
            self.currentTime = currentTime
            prefetchImageLoader = parent.imageLoader
            imagePrefetchCoordinator = parent.imageLoader.makePrefetchCoordinator()
        }

        func attach(to view: MangaVerticalNativeViewport) {
            viewport = view
            view.collectionView.dataSource = self
            view.collectionView.delegate = self
            view.collectionView.register(MangaVerticalCollectionPageCell.self,
                                         forCellWithReuseIdentifier: MangaVerticalCollectionPageCell.reuseIdentifier)
            for gesture in [tapGesture, doubleTapGesture] {
                gesture.cancelsTouchesInView = false
                gesture.delegate = self
                view.addGestureRecognizer(gesture)
            }
            tapGesture.require(toFail: doubleTapGesture)
            view.panGestureRecognizer.addTarget(self, action: #selector(handleBoundaryPan(_:)))
            view.permitsPinch = { [weak self] in
                guard let self else { return false }
                return self.parent.zoomEnabled && !self.parent.pages.isEmpty
            }
            view.onViewportSizeChange = { [weak self] _, previous in
                self?.rebuildLayout(preserving: previous)
                self?.applyPlacementIfNeeded()
            }
            view.onSnapshotChange = { [weak self] snapshot in
                guard let self, !self.isUpdatingLayout else { return }
                if snapshot.isInteracting { self.lastScrollMotionTime = self.currentTime() }
                if snapshot.isDragging { self.pendingControlScrollTarget = nil }
                if snapshot.isZooming || snapshot.isZoomBouncing {
                    self.panIncludedPinch = true
                    self.pendingBoundaryPull = nil
                }
                self.updateWindow()
                self.publishCurrentPageIfNeeded()
            }
            view.onInteractionEnd = { [weak self] in
                self?.applyPendingRatios()
                self?.publishCurrentPageIfNeeded()
            }
        }

        func updateContentIfNeeded(in view: MangaVerticalNativeViewport) {
            if parent.likedPageIDs != lastAppliedLikedPageIDs {
                lastAppliedLikedPageIDs = parent.likedPageIDs
                for case let cell as MangaVerticalCollectionPageCell in view.collectionView.visibleCells {
                    cell.refreshLiked(using: parent.likedPageIDs)
                }
            }
            let nextIdentity = parent.pages.map(\.id)
            if nextIdentity != contentIdentity {
                imagePrefetchCoordinator.cancel()
                lastPrefetchSources = []
                contentIdentity = nextIdentity
                let validIDs = Set(nextIdentity)
                heightToWidthRatios = heightToWidthRatios.filter { validIDs.contains($0.key) }
                pendingRatios = [:]
                ratioUpdateTask?.cancel()
                ratioUpdateTask = nil
                lastReportedGlobalIndex = nil
                pendingReportedGlobalIndex = nil
                cancelPendingCurrentPagePublish()
                pendingControlScrollTarget = nil
                view.stopInteraction()
                view.resetZoom(animated: false)
                pendingInitialPageIndex = parent.pages.isEmpty ? nil
                    : min(max(parent.viewportPlacement?.targetPageIndex ?? parent.currentPageIndex ?? 0, 0), parent.pages.count - 1)
                view.alpha = parent.pages.isEmpty ? 1 : 0
                view.collectionView.reloadData()
                rebuildLayout(preserving: nil)
                lastAppliedControlScrollRevision = parent.controlScrollStep?.revision
            }
            if !parent.zoomEnabled, MangaPageZoomPolicy.isActive(view.normalizedZoomFactor) {
                view.stopInteraction()
                view.resetZoom(animated: false)
            }
            let maximumScale = parent.zoomEnabled ? MangaPageZoomPolicy.maximumScale : 1
            if view.maximumZoomScale != maximumScale { view.maximumZoomScale = maximumScale }
            applyPlacementIfNeeded()
            applyControlScrollStepIfNeeded()
            updateImagePrefetch()
        }

        private func rebuildLayout(preserving previous: NativeZoomSnapshot?) {
            guard let view = viewport, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let screenAnchor = CGPoint(x: view.bounds.width / 2, y: view.bounds.height / 2)
            let anchor = previous.flatMap {
                logicalLayout.anchor(at: CGPoint(x: $0.visibleRect.midX, y: $0.visibleRect.midY),
                                     viewportPoint: screenAnchor)
            }
            isUpdatingLayout = true
            logicalLayout = MangaVerticalCollectionZoomLayout(
                pageIDs: contentIdentity, width: view.bounds.width, heightToWidthRatios: heightToWidthRatios
            )
            layoutRevision += 1
            view.logicalCollectionLayout.logicalLayout = logicalLayout
            view.configureGeometry(
                contentSize: CGSize(width: view.bounds.width, height: max(1, logicalLayout.contentSize.height)),
                maximumFactor: parent.zoomEnabled ? MangaPageZoomPolicy.maximumScale : 1
            )
            if let anchor, let point = logicalLayout.contentPoint(for: anchor) {
                view.place(contentPoint: point, at: anchor.viewportPoint)
            }
            isUpdatingLayout = false
            updateWindow(force: true)
            publishCurrentPageIfNeeded()
        }

        private func updateWindow(force: Bool = false) {
            guard !isUpdatingLayout, let view = viewport, logicalLayout.contentSize.height > 0 else { return }
            let visible = view.snapshot.visibleRect
            let desired = logicalLayout.window(covering: visible)
            let current = view.collectionView.frame
            let protected = current.insetBy(dx: 0, dy: min(current.height / 4, visible.height / 4))
            let actual = visible.intersection(CGRect(origin: .zero, size: logicalLayout.contentSize))
            guard force || !protected.contains(actual) || current.height > desired.height * 1.5 else { return }
            isUpdatingLayout = true
            // Rebase the virtual window atomically. Reused cells and their image
            // bounds must not inherit the outer scroll view's zoom animation.
            UIView.performWithoutAnimation {
                view.collectionView.frame = desired
                view.collectionView.contentOffset = CGPoint(x: 0, y: desired.minY)
                view.collectionView.layoutIfNeeded()
            }
            isUpdatingLayout = false
        }

        func recordHeightToWidthRatio(_ ratio: CGFloat, for pageID: String) {
            guard !isDismantled, ratio.isFinite, ratio > 0, contentIdentity.contains(pageID),
                  abs((heightToWidthRatios[pageID] ?? (1 / 0.72)) - ratio) > 0.001 else { return }
            pendingRatios[pageID] = ratio
            guard ratioUpdateTask == nil else { return }
            ratioUpdateTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.ratioUpdateTask = nil
                self.applyPendingRatios()
            }
        }

        private func applyPendingRatios() {
            // Double-tap zoom uses isZoomAnimating. Keep its host geometry stable
            // until UIKit finishes animating the presentation transform.
            guard !isDismantled, !pendingRatios.isEmpty, let view = viewport,
                  !view.isZooming, !view.isZoomBouncing, !view.isZoomAnimating else { return }
            let previous = view.snapshot
            heightToWidthRatios.merge(pendingRatios) { _, new in new }
            pendingRatios = [:]
            callbackScheduler.performViewUpdate { rebuildLayout(preserving: previous) }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.pages.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MangaVerticalCollectionPageCell.reuseIdentifier, for: indexPath
            )
            guard let cell = cell as? MangaVerticalCollectionPageCell,
                  parent.pages.indices.contains(indexPath.item) else { return cell }
            let page = parent.pages[indexPath.item]
            cell.configure(
                page: page, imageLoader: parent.imageLoader,
                knownHeightToWidthRatio: heightToWidthRatios[page.id],
                isLiked: parent.likedPageIDs.contains(page.id),
                onHeightToWidthRatioChange: { [weak self] ratio in
                    self?.recordHeightToWidthRatio(ratio, for: page.id)
                },
                onLongPress: { [weak self] page in
                    guard let self else { return }
                    let callback = self.parent.onPageLongPress
                    self.callbackScheduler.publish { callback(page) }
                }
            )
            return cell
        }

        private func applyPlacementIfNeeded() {
            guard let view = viewport, !logicalLayout.frames.isEmpty else { return }
            if let index = pendingInitialPageIndex, logicalLayout.frames.indices.contains(index) {
                pendingInitialPageIndex = nil
                lastAppliedPlacementRevision = parent.viewportPlacement?.revision
                view.place(contentPoint: logicalLayout.frames[index].origin, at: .zero)
                view.alpha = 1
            } else if let placement = parent.viewportPlacement, placement.revision != lastAppliedPlacementRevision {
                lastAppliedPlacementRevision = placement.revision
                view.stopInteraction()
                view.resetZoom(animated: false)
                let index = min(max(placement.targetPageIndex, 0), logicalLayout.frames.count - 1)
                view.place(contentPoint: logicalLayout.frames[index].origin, at: .zero, animated: placement.animated)
            }
            updateWindow()
            publishCurrentPageIfNeeded()
        }

        private func applyControlScrollStepIfNeeded() {
            guard pendingInitialPageIndex == nil, let view = viewport, !parent.pages.isEmpty,
                  view.bounds.height > 0, let request = parent.controlScrollStep,
                  request.revision != lastAppliedControlScrollRevision else { return }
            lastAppliedControlScrollRevision = request.revision
            let minY = -view.contentInset.top
            let maxY = max(minY, view.contentSize.height - view.bounds.height + view.contentInset.bottom)
            let currentY = view.contentOffset.y
            let isAtEdge = request.direction == .down ? currentY >= maxY - 0.5 : currentY <= minY + 0.5
            if isAtEdge {
                let callback = parent.onControlScrollEdgeReached
                callbackScheduler.publish { callback(request.direction) }
                return
            }
            let now = currentTime()
            let baseY = pendingControlScrollTarget.flatMap { now - $0.timestamp < 0.45 ? $0.y : nil } ?? currentY
            let step = view.bounds.height * CGFloat(ReaderControlCommandResolver.verticalScrollViewportFraction)
            let target = min(max(baseY + (request.direction == .down ? step : -step), minY), maxY)
            pendingControlScrollTarget = (target, now)
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: !UIAccessibility.isReduceMotionEnabled)
        }

        // Exposed to gesture tests to model a recent scroll even after UIKit has
        // already stopped decelerating at touch-down.
        func scrollViewDidScroll(_ scrollView: UIScrollView) { lastScrollMotionTime = currentTime() }

        @objc func handleBoundaryPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = viewport else { return }
            switch recognizer.state {
            case .began:
                panIncludedPinch = view.isZooming || view.isZoomBouncing || recognizer.numberOfTouches > 1
                pendingBoundaryPull = nil
            case .changed:
                guard !panIncludedPinch, !view.isZooming, !view.isZoomBouncing,
                      recognizer.numberOfTouches == 1, pendingInitialPageIndex == nil,
                      !parent.pages.isEmpty else { pendingBoundaryPull = nil; return }
                let minY = -view.contentInset.top
                let maxY = max(minY, view.contentSize.height - view.bounds.height + view.contentInset.bottom)
                pendingBoundaryPull = ReaderVerticalBoundaryAttempt.boundary(
                    offsetY: view.contentOffset.y, minOffsetY: minY, maxOffsetY: maxY,
                    translationY: recognizer.translation(in: view).y
                )
            case .ended:
                defer { pendingBoundaryPull = nil }
                guard !panIncludedPinch, let boundary = pendingBoundaryPull else { return }
                let callback = parent.onVerticalBoundaryPull
                callbackScheduler.publish { callback(boundary) }
            case .cancelled, .failed:
                pendingBoundaryPull = nil
            default: break
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view as? UIScrollView,
                  canRecognizeTap(in: view) else { return }
            let callback = parent.onTap
            callbackScheduler.publish { callback() }
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = viewport, canRecognizeTap(in: view) else { return }
            if parent.isChromeVisible {
                let callback = parent.onTap
                callbackScheduler.publish { callback() }
                return
            }
            guard parent.zoomEnabled, !parent.pages.isEmpty else { return }
            let factor = MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: view.normalizedZoomFactor)
            if factor == 1 {
                view.resetZoom(animated: true)
            } else {
                view.zoom(factor: factor, centeredAt: recognizer.location(in: view.zoomContentView), animated: true)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.view?.isDescendant(ofType: UIControl.self) != true else { return false }
            guard gestureRecognizer === tapGesture || gestureRecognizer === doubleTapGesture else { return true }
            guard let view = gestureRecognizer.view as? UIScrollView else { return false }
            return canRecognizeTap(in: view)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === tapGesture || gestureRecognizer === doubleTapGesture,
                  let view = gestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === view.panGestureRecognizer || otherGestureRecognizer === view.pinchGestureRecognizer
        }

        private func canRecognizeTap(in view: UIScrollView) -> Bool {
            guard !view.isDragging, !view.isDecelerating, !view.isZooming, !view.isZoomBouncing,
                  view.pinchGestureRecognizer?.state != .began, view.pinchGestureRecognizer?.state != .changed else { return false }
            return lastScrollMotionTime.map { currentTime() - $0 > Self.chromeToggleMotionSuppressionInterval } ?? true
        }

        func visiblePageIndexes() -> [Int] {
            guard pendingInitialPageIndex == nil, let view = viewport else { return [] }
            return Array(logicalLayout.indexes(intersecting: view.snapshot.visibleRect))
        }

        private func publishCurrentPageIfNeeded() {
            updateImagePrefetch()
            guard pendingInitialPageIndex == nil, let view = viewport else { return }
            let visible = view.snapshot.visibleRect
            let index = logicalLayout.indexes(intersecting: visible).max { lhs, rhs in
                let left = visible.intersection(logicalLayout.frames[lhs])
                let right = visible.intersection(logicalLayout.frames[rhs])
                let leftArea = left.width * left.height
                let rightArea = right.width * right.height
                if leftArea == rightArea {
                    return abs(logicalLayout.frames[lhs].minY - visible.minY) > abs(logicalLayout.frames[rhs].minY - visible.minY)
                }
                return leftArea < rightArea
            }
            guard let index else { return }
            pendingReportedGlobalIndex = index
            guard index != lastReportedGlobalIndex, currentPagePublishDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(flushPendingCurrentPagePublish))
            link.add(to: .main, forMode: .common)
            currentPagePublishDisplayLink = link
        }

        @objc private func flushPendingCurrentPagePublish(_ displayLink: CADisplayLink) {
            displayLink.invalidate()
            currentPagePublishDisplayLink = nil
            guard let index = pendingReportedGlobalIndex, index != lastReportedGlobalIndex else { return }
            pendingReportedGlobalIndex = nil
            lastReportedGlobalIndex = index
            parent.onCurrentPageChange(index)
        }

        private func cancelPendingCurrentPagePublish() {
            currentPagePublishDisplayLink?.invalidate()
            currentPagePublishDisplayLink = nil
        }

        func updateImagePrefetch() {
            guard !isDismantled else { return }
            if prefetchImageLoader !== parent.imageLoader {
                imagePrefetchCoordinator.cancel()
                prefetchImageLoader = parent.imageLoader
                imagePrefetchCoordinator = parent.imageLoader.makePrefetchCoordinator()
                lastPrefetchSources = []
            }
            let pages = MangaVerticalImagePrefetchPlan.pagesToPrefetch(
                pages: parent.pages, visiblePageIndexes: visiblePageIndexes(),
                fallbackPageIndex: pendingInitialPageIndex ?? parent.viewportPlacement?.targetPageIndex ?? parent.currentPageIndex ?? 0
            )
            let sources = parent.imageLoader.imageSources(for: pages)
            guard sources != lastPrefetchSources else { return }
            lastPrefetchSources = sources
            imagePrefetchCoordinator.update(sources: sources)
        }

        func dismantle() {
            isDismantled = true
            ratioUpdateTask?.cancel()
            ratioUpdateTask = nil
            imagePrefetchCoordinator.cancel()
            cancelPendingCurrentPagePublish()
            viewport?.onSnapshotChange = nil
            viewport?.onViewportSizeChange = nil
            viewport?.onInteractionEnd = nil
            viewport?.stopInteraction()
            viewport?.collectionView.dataSource = nil
            viewport?.collectionView.delegate = nil
            viewport?.panGestureRecognizer.removeTarget(self, action: #selector(handleBoundaryPan(_:)))
        }
    }
}

final class MangaVerticalNativeViewport: NativeZoomScrollView {
    let logicalCollectionLayout = MangaVerticalNativeCollectionLayout()
    let collectionView: UICollectionView

    override init() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: logicalCollectionLayout)
        super.init()
        centersVertically = false
        alwaysBounceVertical = true
        backgroundColor = .black
        collectionView.isScrollEnabled = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        zoomContentView.addSubview(collectionView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class MangaVerticalCollectionPageCell: UICollectionViewCell {
    static let reuseIdentifier = "MangaVerticalCollectionPageCell"
    static let defaultWidthToHeightAspectRatio: CGFloat = 0.72
    static let defaultEstimatedHeight: CGFloat = 560

    private let imageView = UIImageView()
    private let loadStateOverlay = ReaderLoadStateOverlayView()
    private let likeBadgeImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "heart.fill"))
        imageView.tintColor = .systemPink
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        return imageView
    }()
    private var task: Task<Void, Never>?
    private var page: MangaReaderPageProjection?
    private var imageLoader: MangaReaderPageImageLoader?
    private var currentPageID: String?
    private var heightToWidthRatio = 1 / defaultWidthToHeightAspectRatio
    private var onHeightToWidthRatioChange: ((CGFloat) -> Void)?
    private var onLongPress: ((MangaReaderPageProjection) -> Void)?
    private lazy var longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))

    override init(frame: CGRect) {
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

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        page = nil
        imageLoader = nil
        currentPageID = nil
        onHeightToWidthRatioChange = nil
        onLongPress = nil
        heightToWidthRatio = 1 / Self.defaultWidthToHeightAspectRatio
        imageView.image = nil
        imageView.isHidden = false
        loadStateOverlay.hide()
        likeBadgeImageView.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    func configure(
        page: MangaReaderPageProjection,
        imageLoader: MangaReaderPageImageLoader,
        knownHeightToWidthRatio: CGFloat?,
        isLiked: Bool,
        onHeightToWidthRatioChange: @escaping (CGFloat) -> Void,
        onLongPress: @escaping (MangaReaderPageProjection) -> Void
    ) {
        self.page = page
        self.imageLoader = imageLoader
        self.onHeightToWidthRatioChange = onHeightToWidthRatioChange
        self.onLongPress = onLongPress
        if let knownHeightToWidthRatio {
            heightToWidthRatio = knownHeightToWidthRatio
        }
        likeBadgeImageView.isHidden = !isLiked

        let isSamePage = currentPageID == page.id
        currentPageID = page.id
        if isSamePage, imageView.image != nil {
            return
        }

        task?.cancel()
        if let cachedImage = imageLoader.cachedImage(for: page) {
            show(image: cachedImage, pageID: page.id)
        } else {
            startLoad()
        }
    }

    private func configureViewHierarchy() {
        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        contentView.addSubview(imageView)

        loadStateOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadStateOverlay)
        NSLayoutConstraint.activate([
            loadStateOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loadStateOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loadStateOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            loadStateOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        likeBadgeImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(likeBadgeImageView)
        NSLayoutConstraint.activate([
            likeBadgeImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            likeBadgeImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            likeBadgeImageView.widthAnchor.constraint(equalToConstant: 22),
            likeBadgeImageView.heightAnchor.constraint(equalToConstant: 22)
        ])

        longPressGesture.minimumPressDuration = 0.45
        longPressGesture.cancelsTouchesInView = false
        contentView.addGestureRecognizer(longPressGesture)
    }

    // Called when the liked-page set changes independently of page content
    // (e.g. a like/unlike from this same reader or the Like list sheet), so
    // already-visible cells don't need a full `configure(...)`/image reload.
    func refreshLiked(using likedPageIDs: Set<String>) {
        guard let currentPageID else { return }
        likeBadgeImageView.isHidden = !likedPageIDs.contains(currentPageID)
    }

    private func startLoad() {
        guard let page, let imageLoader else { return }
        showLoading()
        task = Task { @MainActor [weak self] in
            do {
                let image = try await imageLoader.image(for: page)
                guard !Task.isCancelled else { return }
                self?.show(image: image, pageID: page.id)
            } catch {
                guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
                self?.showFailure(pageID: page.id, error: error)
            }
        }
    }

    private func retryImageLoad() {
        task?.cancel()
        startLoad()
    }

    private func showLoading() {
        imageView.image = nil
        imageView.isHidden = true
        loadStateOverlay.show(status: .loading, tintColor: .white)
    }

    private func show(image: UIImage, pageID: String) {
        guard currentPageID == pageID else { return }
        loadStateOverlay.hide()
        imageView.isHidden = false
        imageView.image = image
        setNeedsLayout()
        updateHeightToWidthRatio(for: image)
    }

    private func showFailure(pageID: String, error: any Error) {
        guard currentPageID == pageID else { return }
        imageView.image = nil
        imageView.isHidden = true
        loadStateOverlay.show(
            status: .failed(title: L10n.string("image.load_failed"), message: "", details: LoadFailureDetails(error: error, requestContext: pageID)),
            retryAction: { [weak self] in
                self?.retryImageLoad()
            },
            tintColor: .white
        )
        setNeedsLayout()
    }

    private func updateHeightToWidthRatio(for image: UIImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let nextRatio = image.size.height / image.size.width
        guard nextRatio.isFinite, nextRatio > 0 else { return }
        guard abs(nextRatio - heightToWidthRatio) > 0.001 else { return }
        heightToWidthRatio = nextRatio
        onHeightToWidthRatioChange?(nextRatio)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let imageFrame = ImageContentGeometry.aspectFitFrame(
            imageSize: imageView.image?.size ?? .zero,
            containerSize: imageView.bounds.size
        )
        let imageFrameInPage = imageView.convert(imageFrame, to: contentView)

        guard recognizer.state == .began,
              let page,
              imageView.image != nil,
              MangaPageLongPressHitTesting.acceptsPageLongPress(
                  at: recognizer.location(in: contentView),
                  in: contentView.bounds,
                  imageFrame: imageFrameInPage
              ) else {
            return
        }
        onLongPress?(page)
    }
}

#endif
