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
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let collectionView = MangaVerticalCollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeLayout(
                zoomScaleProvider: { [weak coordinator] in
                    coordinator?.verticalZoomScale ?? MangaPageZoomPolicy.minimumScale
                }
            )
        )
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            MangaVerticalCollectionPageCell.self,
            forCellWithReuseIdentifier: MangaVerticalCollectionPageCell.reuseIdentifier
        )
        collectionView.onLayoutSubviews = { [weak coordinator, weak collectionView] in
            guard let collectionView else { return }
            coordinator?.applyInitialPlacementIfNeeded(in: collectionView)
            coordinator?.applyViewportPlacementIfNeeded(in: collectionView)
        }
        context.coordinator.tapGesture.cancelsTouchesInView = false
        context.coordinator.tapGesture.delegate = context.coordinator
        context.coordinator.tapGesture.require(toFail: context.coordinator.doubleTapGesture)
        collectionView.addGestureRecognizer(context.coordinator.tapGesture)
        context.coordinator.doubleTapGesture.cancelsTouchesInView = false
        context.coordinator.doubleTapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(context.coordinator.doubleTapGesture)
        context.coordinator.pinchGesture.cancelsTouchesInView = false
        context.coordinator.pinchGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(context.coordinator.pinchGesture)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.updateContentIfNeeded(in: collectionView)
        }
    }

    private static func makeLayout(
        zoomScaleProvider: @escaping () -> CGFloat
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let zoomScale = zoomScaleProvider()
            let itemWidth = MangaVerticalCollectionZoomLayout.itemWidth(
                viewportWidth: environment.container.effectiveContentSize.width,
                zoomScale: zoomScale
            )
            let estimatedHeight = MangaVerticalCollectionZoomLayout.estimatedItemHeight(
                baseHeight: MangaVerticalCollectionPageCell.defaultEstimatedHeight,
                zoomScale: zoomScale
            )
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .absolute(itemWidth),
                heightDimension: .estimated(estimatedHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 0
            return section
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: MangaVerticalCollectionViewport
        let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
        private var contentIdentity: [String] = []
        private var heightToWidthRatios: [String: CGFloat] = [:]
        private var lastAppliedLikedPageIDs: Set<String> = []
        private var pendingInitialPageIndex: Int?
        private var lastReportedGlobalIndex: Int?
        private var pendingReportedGlobalIndex: Int?
        private var currentPagePublishDisplayLink: CADisplayLink?
        private var lastAppliedPlacementRevision: Int?
        private var lastAppliedControlScrollRevision: Int?
        private var pendingControlScrollTarget: (y: CGFloat, timestamp: TimeInterval)?
        private(set) var verticalZoomScale = MangaPageZoomPolicy.minimumScale
        private var pinchStartScale: CGFloat?
        private var lastScrollMotionTime = CACurrentMediaTime()
        /// Grace window after real scroll motion in which a completed tap is
        /// treated as "braking the scroll" rather than a chrome toggle.
        /// UIKit halts deceleration synchronously on touch-down, so by the
        /// time this tap's `.ended` fires, `isDecelerating` already reads
        /// false again — the recent-motion timestamp is what still proves
        /// the tap landed on a moving list. Mirrors
        /// `NovelReaderVerticalScrollCoordinator.motionSuppressionInterval`.
        private static let chromeToggleMotionSuppressionInterval: CFTimeInterval = 0.35
        lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        lazy var doubleTapGesture: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            recognizer.numberOfTapsRequired = 2
            return recognizer
        }()
        lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        init(parent: MangaVerticalCollectionViewport) {
            self.parent = parent
        }

        func updateContentIfNeeded(in collectionView: UICollectionView) {
            resetVerticalZoomIfUnavailable(in: collectionView)
            if parent.likedPageIDs != lastAppliedLikedPageIDs {
                lastAppliedLikedPageIDs = parent.likedPageIDs
                for case let cell as MangaVerticalCollectionPageCell in collectionView.visibleCells {
                    cell.refreshLiked(using: parent.likedPageIDs)
                }
            }
            let nextIdentity = parent.pages.map(\.id)
            guard nextIdentity != contentIdentity else {
                applyInitialPlacementIfNeeded(in: collectionView)
                applyViewportPlacementIfNeeded(in: collectionView)
                applyControlScrollStepIfNeeded(in: collectionView)
                return
            }

            contentIdentity = nextIdentity
            let validIDs = Set(nextIdentity)
            heightToWidthRatios = heightToWidthRatios.filter { validIDs.contains($0.key) }
            lastReportedGlobalIndex = nil
            pendingReportedGlobalIndex = nil
            pendingControlScrollTarget = nil
            cancelPendingCurrentPagePublish()
            resetVerticalZoom(in: collectionView, animated: false)

            if parent.pages.isEmpty {
                pendingInitialPageIndex = nil
                collectionView.alpha = 1
            } else {
                let requestedIndex = parent.viewportPlacement?.targetPageIndex ?? parent.currentPageIndex ?? 0
                pendingInitialPageIndex = min(max(requestedIndex, 0), parent.pages.count - 1)
                collectionView.alpha = 0
            }

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.reloadData()
            collectionView.setNeedsLayout()
            collectionView.layoutIfNeeded()
            applyInitialPlacementIfNeeded(in: collectionView)
            applyViewportPlacementIfNeeded(in: collectionView)
            // A scroll step issued against the previous content is stale.
            lastAppliedControlScrollRevision = parent.controlScrollStep?.revision
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.pages.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MangaVerticalCollectionPageCell.reuseIdentifier,
                for: indexPath
            )
            guard let cell = cell as? MangaVerticalCollectionPageCell,
                  parent.pages.indices.contains(indexPath.item) else {
                return cell
            }

            let page = parent.pages[indexPath.item]
            cell.configure(
                page: page,
                imageLoader: parent.imageLoader,
                knownHeightToWidthRatio: heightToWidthRatios[page.id],
                isLiked: parent.likedPageIDs.contains(page.id),
                onHeightToWidthRatioChange: { [weak self, weak collectionView] ratio in
                    self?.heightToWidthRatios[page.id] = ratio
                    collectionView?.collectionViewLayout.invalidateLayout()
                    if let collectionView {
                        self?.publishCurrentPageIfNeeded(from: collectionView)
                    }
                },
                onLongPress: { [weak self] page in
                    guard let self else { return }
                    let onPageLongPress = self.parent.onPageLongPress
                    self.callbackScheduler.publish {
                        onPageLongPress(page)
                    }
                }
            )
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            lastScrollMotionTime = CACurrentMediaTime()
            guard pendingInitialPageIndex == nil,
                  let collectionView = scrollView as? UICollectionView else {
                return
            }
            publishCurrentPageIfNeeded(from: collectionView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate,
                  let collectionView = scrollView as? UICollectionView else {
                return
            }
            publishCurrentPageIfNeeded(from: collectionView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            publishCurrentPageIfNeeded(from: collectionView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            publishCurrentPageIfNeeded(from: collectionView)
        }

        func applyInitialPlacementIfNeeded(in collectionView: UICollectionView) {
            guard let targetIndex = pendingInitialPageIndex else { return }
            guard parent.pages.indices.contains(targetIndex) else {
                pendingInitialPageIndex = nil
                collectionView.alpha = 1
                return
            }
            guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
                return
            }

            collectionView.scrollToItem(
                at: IndexPath(item: targetIndex, section: 0),
                at: .top,
                animated: false
            )
            lastAppliedPlacementRevision = parent.viewportPlacement?.revision
            pendingInitialPageIndex = nil
            collectionView.alpha = 1
            publishCurrentPageIfNeeded(from: collectionView)
        }

        func applyViewportPlacementIfNeeded(in collectionView: UICollectionView) {
            guard pendingInitialPageIndex == nil,
                  let placement = parent.viewportPlacement,
                  placement.revision != lastAppliedPlacementRevision else {
                return
            }
            let targetIndex = min(max(placement.targetPageIndex, 0), max(parent.pages.count - 1, 0))
            guard parent.pages.indices.contains(targetIndex),
                  collectionView.bounds.width > 0,
                  collectionView.bounds.height > 0 else {
                return
            }

            resetVerticalZoom(in: collectionView, animated: false)
            collectionView.scrollToItem(
                at: IndexPath(item: targetIndex, section: 0),
                at: .top,
                animated: placement.animated
            )
            lastAppliedPlacementRevision = placement.revision
            publishCurrentPageIfNeeded(from: collectionView)
        }

        /// Grace window in which a still-animating step's target keeps serving
        /// as the base for the next one, so rapid presses compound instead of
        /// re-reading the mid-animation offset.
        private static let controlScrollAnimationGrace: TimeInterval = 0.45

        func applyControlScrollStepIfNeeded(in collectionView: UICollectionView) {
            guard pendingInitialPageIndex == nil,
                  let request = parent.controlScrollStep,
                  request.revision != lastAppliedControlScrollRevision else {
                return
            }
            guard !parent.pages.isEmpty,
                  collectionView.bounds.height > 0 else {
                return
            }
            lastAppliedControlScrollRevision = request.revision

            let minOffsetY = -collectionView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                collectionView.contentSize.height - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            let currentY = collectionView.contentOffset.y
            let edgeTolerance: CGFloat = 0.5

            // Already clamped at the edge when pressed: report instead of
            // scrolling so the reader can cross to the adjacent chapter.
            let isAtEdge = switch request.direction {
            case .down: currentY >= maxOffsetY - edgeTolerance
            case .up: currentY <= minOffsetY + edgeTolerance
            }
            if isAtEdge {
                let onControlScrollEdgeReached = parent.onControlScrollEdgeReached
                let direction = request.direction
                callbackScheduler.publish {
                    onControlScrollEdgeReached(direction)
                }
                return
            }

            let now = CACurrentMediaTime()
            var baseY = currentY
            if let pending = pendingControlScrollTarget,
               now - pending.timestamp < Self.controlScrollAnimationGrace {
                baseY = pending.y
            }
            let step = collectionView.bounds.height
                * CGFloat(ReaderControlCommandResolver.verticalScrollViewportFraction)
            let desiredY = request.direction == .down ? baseY + step : baseY - step
            let targetY = min(max(desiredY, minOffsetY), maxOffsetY)
            pendingControlScrollTarget = (targetY, now)
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: targetY),
                animated: true
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pendingControlScrollTarget = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let sinceLastMotion = CACurrentMediaTime() - lastScrollMotionTime
            guard sinceLastMotion > Self.chromeToggleMotionSuppressionInterval else { return }
            let onTap = parent.onTap
            callbackScheduler.publish {
                onTap()
            }
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let collectionView = recognizer.view as? UICollectionView else {
                return
            }

            if parent.isChromeVisible {
                let onTap = parent.onTap
                callbackScheduler.publish {
                    onTap()
                }
                return
            }

            guard parent.zoomEnabled,
                  !parent.pages.isEmpty else {
                return
            }
            let targetScale = MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: verticalZoomScale)
            setVerticalZoomScale(
                targetScale,
                in: collectionView,
                anchorPointInContent: recognizer.location(in: collectionView),
                animated: true
            )
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let collectionView = recognizer.view as? UICollectionView,
                  parent.zoomEnabled,
                  !parent.isChromeVisible,
                  !parent.pages.isEmpty else {
                pinchStartScale = nil
                return
            }

            switch recognizer.state {
            case .began:
                pinchStartScale = verticalZoomScale
            case .changed:
                let startScale = pinchStartScale ?? verticalZoomScale
                let targetScale = MangaVerticalCollectionZoomLayout.clampedScale(startScale * recognizer.scale)
                setVerticalZoomScale(
                    targetScale,
                    in: collectionView,
                    anchorPointInContent: recognizer.location(in: collectionView),
                    animated: false
                )
            case .ended, .cancelled, .failed:
                let targetScale = MangaPageZoomPolicy.isActive(verticalZoomScale)
                    ? verticalZoomScale
                    : MangaPageZoomPolicy.minimumScale
                setVerticalZoomScale(
                    targetScale,
                    in: collectionView,
                    anchorPointInContent: recognizer.location(in: collectionView),
                    animated: true
                )
                pinchStartScale = nil
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.view?.isDescendant(ofType: UIControl.self) != true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pinchGesture else { return true }
            return parent.zoomEnabled && !parent.isChromeVisible && !parent.pages.isEmpty
        }

        private func resetVerticalZoomIfUnavailable(in collectionView: UICollectionView) {
            guard parent.isChromeVisible || !parent.zoomEnabled else { return }
            resetVerticalZoom(in: collectionView, animated: true)
        }

        private func resetVerticalZoom(in collectionView: UICollectionView, animated: Bool) {
            let anchorPoint = CGPoint(
                x: collectionView.contentOffset.x + collectionView.bounds.midX,
                y: collectionView.contentOffset.y + collectionView.bounds.midY
            )
            setVerticalZoomScale(
                MangaPageZoomPolicy.minimumScale,
                in: collectionView,
                anchorPointInContent: anchorPoint,
                animated: animated
            )
        }

        private func setVerticalZoomScale(
            _ scale: CGFloat,
            in collectionView: UICollectionView,
            anchorPointInContent: CGPoint,
            animated: Bool
        ) {
            guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
                verticalZoomScale = MangaVerticalCollectionZoomLayout.clampedScale(scale)
                return
            }
            let oldScale = verticalZoomScale
            let targetScale = MangaVerticalCollectionZoomLayout.clampedScale(scale)
            let currentOffset = collectionView.contentOffset
            let visibleAnchor = CGPoint(
                x: min(max(anchorPointInContent.x - currentOffset.x, 0), collectionView.bounds.width),
                y: min(max(anchorPointInContent.y - currentOffset.y, 0), collectionView.bounds.height)
            )
            let projectedContentSize = MangaVerticalCollectionZoomLayout.projectedContentSize(
                currentContentSize: collectionView.contentSize,
                viewportSize: collectionView.bounds.size,
                oldScale: oldScale,
                newScale: targetScale
            )
            let targetOffset = MangaVerticalCollectionZoomLayout.anchoredContentOffset(
                currentOffset: currentOffset,
                visibleAnchor: visibleAnchor,
                oldScale: oldScale,
                newScale: targetScale,
                targetContentSize: projectedContentSize,
                viewportSize: collectionView.bounds.size,
                adjustedContentInset: collectionView.adjustedContentInset.verticalZoomInsets
            )

            guard abs(targetScale - oldScale) > 0.001 else {
                clampContentOffset(in: collectionView, animated: animated)
                return
            }

            verticalZoomScale = targetScale
            let updates = {
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(targetOffset, animated: false)
            }
            if animated {
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                    animations: updates,
                    completion: { [weak self, weak collectionView] _ in
                        guard let self, let collectionView else { return }
                        self.clampContentOffset(in: collectionView, animated: false)
                        self.publishCurrentPageIfNeeded(from: collectionView)
                    }
                )
            } else {
                UIView.performWithoutAnimation(updates)
                clampContentOffset(in: collectionView, animated: false)
            }
            publishCurrentPageIfNeeded(from: collectionView)
        }

        private func clampContentOffset(in collectionView: UICollectionView, animated: Bool) {
            let clampedOffset = MangaVerticalCollectionZoomLayout.clampedContentOffset(
                collectionView.contentOffset,
                contentSize: collectionView.contentSize,
                viewportSize: collectionView.bounds.size,
                adjustedContentInset: collectionView.adjustedContentInset.verticalZoomInsets
            )
            guard clampedOffset != collectionView.contentOffset else { return }
            collectionView.setContentOffset(clampedOffset, animated: animated)
        }

        private func publishCurrentPageIfNeeded(from collectionView: UICollectionView) {
            guard let globalIndex = currentGlobalIndex(in: collectionView),
                  globalIndex != lastReportedGlobalIndex else {
                return
            }

            pendingReportedGlobalIndex = globalIndex
            guard currentPagePublishDisplayLink == nil else { return }

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(flushPendingCurrentPagePublish)
            )
            displayLink.add(to: .main, forMode: .common)
            currentPagePublishDisplayLink = displayLink
        }

        @objc private func flushPendingCurrentPagePublish(_ displayLink: CADisplayLink) {
            displayLink.invalidate()
            currentPagePublishDisplayLink = nil

            guard let globalIndex = pendingReportedGlobalIndex,
                  globalIndex != lastReportedGlobalIndex else {
                pendingReportedGlobalIndex = nil
                return
            }
            pendingReportedGlobalIndex = nil
            lastReportedGlobalIndex = globalIndex
            parent.onCurrentPageChange(globalIndex)
        }

        private func cancelPendingCurrentPagePublish() {
            currentPagePublishDisplayLink?.invalidate()
            currentPagePublishDisplayLink = nil
        }

        private func currentGlobalIndex(in collectionView: UICollectionView) -> Int? {
            let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
            return collectionView.indexPathsForVisibleItems
                .compactMap { indexPath -> (index: Int, visibleArea: CGFloat, topDistance: CGFloat)? in
                    guard parent.pages.indices.contains(indexPath.item),
                          let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                        return nil
                    }
                    let intersection = visibleRect.intersection(attributes.frame)
                    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                        return nil
                    }
                    return (
                        index: indexPath.item,
                        visibleArea: intersection.width * intersection.height,
                        topDistance: abs(attributes.frame.minY - visibleRect.minY)
                    )
                }
                .max { lhs, rhs in
                    if lhs.visibleArea == rhs.visibleArea {
                        return lhs.topDistance > rhs.topDistance
                    }
                    return lhs.visibleArea < rhs.visibleArea
                }?.index
        }
    }
}

private final class MangaVerticalCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
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

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = max(attributes.size.width, 1)
        attributes.size.height = max(ceil(width * heightToWidthRatio), 160)
        return attributes
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
                guard !Task.isCancelled else { return }
                self?.showFailure(pageID: page.id)
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

    private func showFailure(pageID: String) {
        guard currentPageID == pageID else { return }
        imageView.image = nil
        imageView.isHidden = true
        loadStateOverlay.show(
            status: .failed(title: L10n.string("image.load_failed"), message: ""),
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

private extension UIEdgeInsets {
    var verticalZoomInsets: MangaVerticalCollectionZoomInsets {
        MangaVerticalCollectionZoomInsets(
            top: top,
            left: left,
            bottom: bottom,
            right: right
        )
    }
}
#endif
