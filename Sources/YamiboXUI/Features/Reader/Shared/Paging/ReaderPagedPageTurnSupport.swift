import Foundation
import SwiftUI
import YamiboXCore

struct ReaderPagedPageTurnVisualMetrics: Equatable {
    var roundedPageIndex: Int
    var maskedPageIndex: Int
    var overlayAlpha: CGFloat
    var cornerRadius: CGFloat

    var isActive: Bool {
        overlayAlpha > 0
    }
}

enum ReaderPagedPageTurnPresentation {
    static let maxOverlayAlpha: CGFloat = 0.22
    static let fallbackPageCornerRadius: CGFloat = 56
    private static let completionThreshold: CGFloat = 0.001

    static func metrics(
        contentOffsetX: CGFloat,
        pageWidth: CGFloat,
        pageCount: Int,
        restingPageIndex: Int,
        maxOverlayAlpha: CGFloat = Self.maxOverlayAlpha,
        cornerRadius: CGFloat = Self.fallbackPageCornerRadius
    ) -> ReaderPagedPageTurnVisualMetrics? {
        guard pageWidth > 0, pageCount > 1 else { return nil }

        let progress = contentOffsetX / pageWidth
        let clampedRestingIndex = min(max(restingPageIndex, 0), max(pageCount - 1, 0))
        let delta = progress - CGFloat(clampedRestingIndex)
        guard abs(delta) > completionThreshold else { return nil }

        let targetIndex = delta > 0 ? clampedRestingIndex + 1 : clampedRestingIndex - 1
        guard targetIndex >= 0, targetIndex < pageCount else { return nil }

        let turnProgress = min(max(abs(delta), 0), 1)
        guard turnProgress < 1 - completionThreshold else { return nil }

        return ReaderPagedPageTurnVisualMetrics(
            roundedPageIndex: clampedRestingIndex,
            maskedPageIndex: targetIndex,
            overlayAlpha: maxOverlayAlpha * (1 - turnProgress),
            cornerRadius: cornerRadius
        )
    }
}

enum ReaderPagedHorizontalNavigationDirection: Equatable {
    case leftSwipeAdvances
    case rightSwipeAdvances
}

extension ReaderPageTurnDirection {
    var horizontalNavigationDirection: ReaderPagedHorizontalNavigationDirection {
        switch self {
        case .leftToRight:
            .leftSwipeAdvances
        case .rightToLeft:
            .rightSwipeAdvances
        }
    }

    var progressFillDirection: ReaderProgressFillDirection {
        switch self {
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        }
    }

    func directionalTapZone(for zone: ReaderPagedTapZone) -> ReaderPagedTapZone {
        switch (self, zone) {
        case (.rightToLeft, .previous):
            .next
        case (.rightToLeft, .next):
            .previous
        default:
            zone
        }
    }

    func itemIndex(forSelectionIndex selectionIndex: Int, itemCount: Int) -> Int {
        let clampedSelectionIndex = clampedIndex(selectionIndex, itemCount: itemCount)
        switch self {
        case .leftToRight:
            return clampedSelectionIndex
        case .rightToLeft:
            return max(itemCount - 1, 0) - clampedSelectionIndex
        }
    }

    func selectionIndex(forItemIndex itemIndex: Int, itemCount: Int) -> Int {
        let clampedItemIndex = clampedIndex(itemIndex, itemCount: itemCount)
        switch self {
        case .leftToRight:
            return clampedItemIndex
        case .rightToLeft:
            return max(itemCount - 1, 0) - clampedItemIndex
        }
    }

    private func clampedIndex(_ index: Int, itemCount: Int) -> Int {
        min(max(index, 0), max(itemCount - 1, 0))
    }
}

struct ReaderPagedBoundaryPageTurn {
    static let minimumTranslation: CGFloat = 48
    static let translationWidthFactor: CGFloat = 0.18
    static let velocityThreshold: CGFloat = 450

    static func horizontalDelta(
        translation: CGPoint,
        velocity: CGPoint,
        viewportWidth: CGFloat
    ) -> Int? {
        if abs(velocity.x) >= velocityThreshold, abs(velocity.x) > abs(velocity.y) {
            return velocity.x < 0 ? 1 : -1
        }

        let translationThreshold = max(
            minimumTranslation,
            viewportWidth * translationWidthFactor
        )
        guard abs(translation.x) >= translationThreshold, abs(translation.x) > abs(translation.y) else {
            return nil
        }
        return translation.x < 0 ? 1 : -1
    }

    static func directionalDelta(
        _ physicalDelta: Int,
        direction: ReaderPagedHorizontalNavigationDirection
    ) -> Int {
        switch direction {
        case .leftSwipeAdvances:
            physicalDelta
        case .rightSwipeAdvances:
            -physicalDelta
        }
    }

    static func boundaryDelta(
        selectionIndex: Int,
        itemCount: Int,
        translation: CGPoint,
        velocity: CGPoint,
        viewportWidth: CGFloat,
        canBoundaryPageTurn: (Int) -> Bool
    ) -> Int? {
        boundaryDelta(
            selectionIndex: selectionIndex,
            itemCount: itemCount,
            translation: translation,
            velocity: velocity,
            viewportWidth: viewportWidth,
            horizontalNavigationDirection: .leftSwipeAdvances,
            canBoundaryPageTurn: canBoundaryPageTurn
        )
    }

    static func boundaryDelta(
        selectionIndex: Int,
        itemCount: Int,
        translation: CGPoint,
        velocity: CGPoint,
        viewportWidth: CGFloat,
        horizontalNavigationDirection: ReaderPagedHorizontalNavigationDirection,
        canBoundaryPageTurn: (Int) -> Bool
    ) -> Int? {
        guard itemCount > 0,
              let physicalDelta = horizontalDelta(
                  translation: translation,
                  velocity: velocity,
                  viewportWidth: viewportWidth
              ) else {
            return nil
        }
        let delta = directionalDelta(physicalDelta, direction: horizontalNavigationDirection)
        let targetSelectionIndex = selectionIndex + delta
        guard targetSelectionIndex < 0 || targetSelectionIndex >= itemCount else { return nil }
        return canBoundaryPageTurn(delta) ? delta : nil
    }
}

enum ReaderPagedQuickFadeTransition {
    static let duration: TimeInterval = 0.18
}

#if os(iOS)
import UIKit

enum ReaderPagedPageTurnBackground {
    static func dimmedPageColor(
        baseColor: UIColor,
        overlayAlpha: CGFloat
    ) -> UIColor {
        blend(base: baseColor, overlay: .black, alpha: min(max(overlayAlpha, 0), 1))
    }

    private static func blend(base: UIColor, overlay: UIColor, alpha: CGFloat) -> UIColor {
        var baseRed: CGFloat = 0
        var baseGreen: CGFloat = 0
        var baseBlue: CGFloat = 0
        var baseAlpha: CGFloat = 0
        var overlayRed: CGFloat = 0
        var overlayGreen: CGFloat = 0
        var overlayBlue: CGFloat = 0
        var overlayAlpha: CGFloat = 0

        base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        overlay.getRed(&overlayRed, green: &overlayGreen, blue: &overlayBlue, alpha: &overlayAlpha)

        return UIColor(
            red: baseRed * (1 - alpha) + overlayRed * alpha,
            green: baseGreen * (1 - alpha) + overlayGreen * alpha,
            blue: baseBlue * (1 - alpha) + overlayBlue * alpha,
            alpha: baseAlpha
        )
    }
}

enum ReaderPagedPageTurnCornerRadius {
    static let fallbackRadius = ReaderPagedPageTurnPresentation.fallbackPageCornerRadius
    private static let displayCornerRadiusSelectorName = ["_display", "Corner", "Radius"].joined()

    static func radius(for screen: UIScreen?) -> CGFloat {
        guard let screen else { return fallbackRadius }
        let selector = NSSelectorFromString(displayCornerRadiusSelectorName)
        guard screen.responds(to: selector),
              let value = screen.value(forKey: displayCornerRadiusSelectorName) as? NSNumber else {
            return fallbackRadius
        }
        let radius = CGFloat(truncating: value)
        return radius > 0 ? radius : fallbackRadius
    }
}

final class ReaderPagedCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

final class ReaderPagedPageTurnCell: UICollectionViewCell {
    private let pageTurnOverlayView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePageTurnOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePageTurnOverlay()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        resetPageTurnVisuals()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensurePageTurnOverlay()
        pageTurnOverlayView.frame = bounds
        bringSubviewToFront(pageTurnOverlayView)
    }

    func applyPageTurnVisuals(overlayAlpha: CGFloat, cornerRadius: CGFloat) {
        ensurePageTurnOverlay()
        pageTurnOverlayView.alpha = min(max(overlayAlpha, 0), 1)
        layer.cornerRadius = max(cornerRadius, 0)
        layer.cornerCurve = .continuous
        layer.masksToBounds = cornerRadius > 0
        bringSubviewToFront(pageTurnOverlayView)
    }

    func resetPageTurnVisuals() {
        ensurePageTurnOverlay()
        pageTurnOverlayView.alpha = 0
        layer.cornerRadius = 0
        layer.masksToBounds = false
    }

    private func configurePageTurnOverlay() {
        pageTurnOverlayView.backgroundColor = .black
        pageTurnOverlayView.alpha = 0
        pageTurnOverlayView.isUserInteractionEnabled = false
        pageTurnOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ensurePageTurnOverlay()
    }

    private func ensurePageTurnOverlay() {
        guard pageTurnOverlayView.superview !== self else { return }
        pageTurnOverlayView.removeFromSuperview()
        addSubview(pageTurnOverlayView)
    }
}

struct ReaderPagedScrollAnimationRequest: Equatable {
    let id: UUID
    let pagerIdentity: ReaderPagedPagerIdentity
    let selectionIndex: Int

    init(
        id: UUID = UUID(),
        pagerIdentity: ReaderPagedPagerIdentity,
        selectionIndex: Int
    ) {
        self.id = id
        self.pagerIdentity = pagerIdentity
        self.selectionIndex = max(0, selectionIndex)
    }
}

struct ReaderPagedPagingInputs: @unchecked Sendable {
    var itemCount: Int
    var selectionIndex: Int
    var pagedTurnStyle: ReaderPagedTurnStyle
    var horizontalNavigationDirection: ReaderPagedHorizontalNavigationDirection
    var pagerIdentity: ReaderPagedPagerIdentity
    var scrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    var canBoundaryPageTurn: (Int) -> Bool
    var onSelectionChange: (Int) -> Void
    var onBoundaryPageTurn: (Int) -> Void
    var onScrollAnimationRequestConsumed: (ReaderPagedScrollAnimationRequest) -> Void
    var pageTurnRestingBackgroundColor: (UITraitCollection) -> UIColor
    var pageTurnBackgroundColor: (UITraitCollection, CGFloat) -> UIColor
    var itemIndexForSelectionIndex: (Int) -> Int = { $0 }
    var selectionIndexForItemIndex: (Int) -> Int = { $0 }
}

@MainActor
final class ReaderPagedPagingDriver {
    private static let quickFadeDuration: TimeInterval = ReaderPagedQuickFadeTransition.duration

    let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
    private var pendingSelectionIndex: Int?
    private var isReloadingDataForSelectionScroll = false
    private var isPendingSelectionScrollRetryScheduled = false
    private var consumedScrollAnimationRequestID: UUID?
    private var pageTurnRestingIndex: Int?
    private var isPerformingQuickFadeTransition = false

    func updateContentAndRequestSelectionScroll(
        in collectionView: UICollectionView,
        didChangeContentIdentity: Bool,
        inputs: ReaderPagedPagingInputs
    ) {
        let animationRequest = matchingScrollAnimationRequest(inputs: inputs)
        guard didChangeContentIdentity else {
            if let animationRequest {
                _ = requestSelectionScroll(
                    in: collectionView,
                    animated: true,
                    inputs: inputs
                ) { [weak self] in
                    self?.consumeScrollAnimationRequest(animationRequest, inputs: inputs)
                }
            } else {
                _ = requestSelectionScroll(in: collectionView, animated: false, inputs: inputs)
            }
            return
        }
        if let animationRequest {
            consumeScrollAnimationRequest(animationRequest, inputs: inputs)
        }
        collectionView.collectionViewLayout.invalidateLayout()
        reloadDataAndRequestSelectionScroll(in: collectionView, animated: false, inputs: inputs)
    }

    func reloadDataAndRequestSelectionScroll(
        in collectionView: UICollectionView,
        animated: Bool,
        inputs: ReaderPagedPagingInputs
    ) {
        pendingSelectionIndex = inputs.selectionIndex
        isReloadingDataForSelectionScroll = true
        collectionView.reloadData()
        collectionView.performBatchUpdates(nil) { [weak self, weak collectionView] _ in
            guard let collectionView else { return }
            self?.isReloadingDataForSelectionScroll = false
            self?.requestSelectionScroll(in: collectionView, animated: animated, inputs: inputs)
            self?.scrollToPendingSelectionIfPossible(in: collectionView, animated: animated, inputs: inputs)
        }
    }

    @discardableResult
    func requestSelectionScroll(
        in collectionView: UICollectionView,
        animated: Bool,
        inputs: ReaderPagedPagingInputs,
        onTransitionCompletion: (() -> Void)? = nil
    ) -> Bool {
        pendingSelectionIndex = inputs.selectionIndex
        return scrollToPendingSelectionIfPossible(
            in: collectionView,
            animated: animated,
            inputs: inputs,
            onTransitionCompletion: onTransitionCompletion
        )
    }

    @discardableResult
    func scrollToPendingSelectionIfPossible(
        in collectionView: UICollectionView,
        animated: Bool,
        inputs: ReaderPagedPagingInputs,
        onTransitionCompletion: (() -> Void)? = nil
    ) -> Bool {
        guard let pendingSelectionIndex,
              !isReloadingDataForSelectionScroll,
              inputs.itemCount > 0,
              collectionView.bounds.width > 0,
              collectionView.window != nil else {
            return false
        }
        let selectionIndex = clampedSelectionIndex(pendingSelectionIndex, inputs: inputs)
        let item = itemIndex(for: selectionIndex, inputs: inputs)
        guard collectionView.numberOfSections > 0,
              collectionView.numberOfItems(inSection: 0) > item else {
            schedulePendingSelectionScrollRetry(in: collectionView, animated: animated, inputs: inputs)
            return false
        }

        collectionView.layoutIfNeeded()
        let targetContentOffsetX = CGFloat(item) * collectionView.bounds.width
        guard collectionView.contentSize.width >= targetContentOffsetX + collectionView.bounds.width else {
            schedulePendingSelectionScrollRetry(in: collectionView, animated: animated, inputs: inputs)
            return false
        }

        return performSelectionTransition(
            to: selectionIndex,
            targetContentOffsetX: targetContentOffsetX,
            in: collectionView,
            animated: animated,
            inputs: inputs,
            onTransitionCompletion: onTransitionCompletion
        )
    }

    func animateAdjacentSelection(
        for zone: ReaderPagedTapZone,
        in collectionView: UICollectionView,
        inputs: ReaderPagedPagingInputs
    ) -> Bool {
        let delta: Int
        switch zone {
        case .previous:
            delta = -1
        case .next:
            delta = 1
        case .toggleChrome:
            return false
        }

        guard inputs.itemCount > 0,
              collectionView.bounds.width > 0,
              collectionView.window != nil else {
            return false
        }
        let targetSelectionIndex = inputs.selectionIndex + delta
        guard targetSelectionIndex >= 0, targetSelectionIndex < inputs.itemCount else {
            return false
        }
        pendingSelectionIndex = targetSelectionIndex
        return scrollToPendingSelectionIfPossible(in: collectionView, animated: true, inputs: inputs)
    }

    func updateGestureState(in collectionView: UICollectionView, inputs: ReaderPagedPagingInputs) {
        collectionView.panGestureRecognizer.isEnabled = inputs.pagedTurnStyle != .quickFade
        if inputs.pagedTurnStyle == .quickFade {
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
        }
    }

    func quickFadePanShouldBegin(_ recognizer: UIPanGestureRecognizer, inputs: ReaderPagedPagingInputs) -> Bool {
        guard inputs.pagedTurnStyle == .quickFade,
              inputs.itemCount > 0,
              let view = recognizer.view else {
            return false
        }
        let velocity = recognizer.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
    }

    func handleQuickFadePan(_ recognizer: UIPanGestureRecognizer, inputs: ReaderPagedPagingInputs) {
        guard inputs.pagedTurnStyle == .quickFade,
              let collectionView = recognizer.view as? UICollectionView else {
            return
        }

        switch recognizer.state {
        case .ended:
            guard let delta = horizontalPanDelta(for: recognizer, in: collectionView, inputs: inputs) else { return }
            let targetSelectionIndex = inputs.selectionIndex + delta
            guard targetSelectionIndex >= 0, targetSelectionIndex < inputs.itemCount else {
                publishBoundaryPageTurnIfPossible(delta, inputs: inputs)
                return
            }
            pendingSelectionIndex = targetSelectionIndex
            _ = scrollToPendingSelectionIfPossible(in: collectionView, animated: true, inputs: inputs)
        case .cancelled, .failed:
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
        default:
            break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView, inputs: ReaderPagedPagingInputs) {
        guard let collectionView = scrollView as? UICollectionView else { return }
        guard inputs.pagedTurnStyle != .quickFade else {
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
            return
        }
        beginPageTurnVisuals(in: collectionView, inputs: inputs)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView, inputs: ReaderPagedPagingInputs) {
        guard let collectionView = scrollView as? UICollectionView else { return }
        guard inputs.pagedTurnStyle != .quickFade else {
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
            return
        }
        applyPageTurnVisuals(in: collectionView, inputs: inputs)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool,
        inputs: ReaderPagedPagingInputs
    ) {
        guard let collectionView = scrollView as? UICollectionView else { return }
        if publishBoundaryPageTurnIfPossible(from: collectionView.panGestureRecognizer, in: collectionView, inputs: inputs) {
            endPageTurnVisuals(in: collectionView, inputs: inputs)
            return
        }
        if !decelerate {
            updateSelection(from: scrollView, inputs: inputs)
            endPageTurnVisuals(in: collectionView, inputs: inputs)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView, inputs: ReaderPagedPagingInputs) {
        updateSelection(from: scrollView, inputs: inputs)
        guard let collectionView = scrollView as? UICollectionView else { return }
        endPageTurnVisuals(in: collectionView, inputs: inputs)
    }

    @discardableResult
    func publishBoundaryPageTurnIfPossible(
        from recognizer: UIPanGestureRecognizer,
        in view: UIView,
        inputs: ReaderPagedPagingInputs
    ) -> Bool {
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        guard let delta = ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: inputs.selectionIndex,
            itemCount: inputs.itemCount,
            translation: translation,
            velocity: velocity,
            viewportWidth: view.bounds.width,
            horizontalNavigationDirection: inputs.horizontalNavigationDirection,
            canBoundaryPageTurn: inputs.canBoundaryPageTurn
        ) else {
            return false
        }
        publishBoundaryPageTurnIfPossible(delta, inputs: inputs)
        return true
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView, inputs: ReaderPagedPagingInputs) {
        updateSelection(from: scrollView, inputs: inputs)
        guard let collectionView = scrollView as? UICollectionView else { return }
        endPageTurnVisuals(in: collectionView, inputs: inputs)
    }

    private func schedulePendingSelectionScrollRetry(
        in collectionView: UICollectionView,
        animated: Bool,
        inputs: ReaderPagedPagingInputs
    ) {
        guard !isPendingSelectionScrollRetryScheduled else { return }
        isPendingSelectionScrollRetryScheduled = true
        DispatchQueue.main.async { [weak self, weak collectionView] in
            guard let self else { return }
            self.isPendingSelectionScrollRetryScheduled = false
            guard let collectionView else { return }
            self.scrollToPendingSelectionIfPossible(in: collectionView, animated: animated, inputs: inputs)
        }
    }

    private func updateSelection(from scrollView: UIScrollView, inputs: ReaderPagedPagingInputs) {
        guard scrollView.bounds.width > 0 else { return }
        let item = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        let clampedItem = min(max(item, 0), max(inputs.itemCount - 1, 0))
        publishSelectionIfNeeded(selectionIndex(forItemIndex: clampedItem, inputs: inputs), inputs: inputs)
    }

    private func publishSelectionIfNeeded(_ selectionIndex: Int, inputs: ReaderPagedPagingInputs) {
        let clampedItem = min(max(selectionIndex, 0), max(inputs.itemCount - 1, 0))
        guard clampedItem != inputs.selectionIndex else { return }
        let onSelectionChange = inputs.onSelectionChange
        callbackScheduler.publish {
            onSelectionChange(clampedItem)
        }
    }

    @discardableResult
    private func performSelectionTransition(
        to selectionIndex: Int,
        targetContentOffsetX: CGFloat,
        in collectionView: UICollectionView,
        animated: Bool,
        inputs: ReaderPagedPagingInputs,
        onTransitionCompletion: (() -> Void)? = nil
    ) -> Bool {
        if animated, inputs.pagedTurnStyle == .quickFade, isPerformingQuickFadeTransition {
            // A rapid second turn mid-fade must not be swallowed: perform it
            // as an immediate cut underneath the in-flight snapshot, which
            // keeps fading out over the newest target page.
            return performSelectionTransition(
                to: selectionIndex,
                targetContentOffsetX: targetContentOffsetX,
                in: collectionView,
                animated: false,
                inputs: inputs,
                onTransitionCompletion: onTransitionCompletion
            )
        }

        let targetOffset = CGPoint(x: targetContentOffsetX, y: collectionView.contentOffset.y)
        guard animated else {
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
            collectionView.setContentOffset(targetOffset, animated: false)
            collectionView.layoutIfNeeded()
            pendingSelectionIndex = nil
            publishSelectionIfNeeded(selectionIndex, inputs: inputs)
            onTransitionCompletion?()
            return true
        }

        switch inputs.pagedTurnStyle {
        case .slide, .pageCurl:
            beginPageTurnVisuals(in: collectionView, inputs: inputs)
            collectionView.setContentOffset(targetOffset, animated: true)
            applyPageTurnVisuals(in: collectionView, inputs: inputs)
            pendingSelectionIndex = nil
            onTransitionCompletion?()
        case .quickFade:
            isPerformingQuickFadeTransition = true
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
            guard let quickFadeSnapshot = collectionView.snapshotView(afterScreenUpdates: false) else {
                collectionView.setContentOffset(targetOffset, animated: false)
                collectionView.layoutIfNeeded()
                isPerformingQuickFadeTransition = false
                pendingSelectionIndex = nil
                publishSelectionIfNeeded(selectionIndex, inputs: inputs)
                onTransitionCompletion?()
                return true
            }

            quickFadeSnapshot.isUserInteractionEnabled = false
            if let snapshotContainer = collectionView.superview {
                quickFadeSnapshot.frame = collectionView.convert(collectionView.bounds, to: snapshotContainer)
                snapshotContainer.addSubview(quickFadeSnapshot)
            } else {
                quickFadeSnapshot.frame = CGRect(origin: targetOffset, size: collectionView.bounds.size)
                collectionView.addSubview(quickFadeSnapshot)
            }
            collectionView.setContentOffset(targetOffset, animated: false)
            collectionView.layoutIfNeeded()
            UIView.animate(
                withDuration: Self.quickFadeDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                quickFadeSnapshot.alpha = 0
            } completion: { [weak self] _ in
                quickFadeSnapshot.removeFromSuperview()
                guard let self else { return }
                self.isPerformingQuickFadeTransition = false
                self.pendingSelectionIndex = nil
                self.publishSelectionIfNeeded(selectionIndex, inputs: inputs)
                onTransitionCompletion?()
            }
        }
        return true
    }

    private func horizontalPanDelta(
        for recognizer: UIPanGestureRecognizer,
        in collectionView: UICollectionView,
        inputs: ReaderPagedPagingInputs
    ) -> Int? {
        guard let physicalDelta = ReaderPagedBoundaryPageTurn.horizontalDelta(
            translation: recognizer.translation(in: collectionView),
            velocity: recognizer.velocity(in: collectionView),
            viewportWidth: collectionView.bounds.width
        ) else {
            return nil
        }
        return ReaderPagedBoundaryPageTurn.directionalDelta(
            physicalDelta,
            direction: inputs.horizontalNavigationDirection
        )
    }

    private func publishBoundaryPageTurnIfPossible(_ delta: Int, inputs: ReaderPagedPagingInputs) {
        guard inputs.canBoundaryPageTurn(delta) else { return }
        let onBoundaryPageTurn = inputs.onBoundaryPageTurn
        callbackScheduler.publish {
            onBoundaryPageTurn(delta)
        }
    }

    private func beginPageTurnVisuals(in collectionView: UICollectionView, inputs: ReaderPagedPagingInputs) {
        guard collectionView.bounds.width > 0 else { return }
        let currentIndex = Int((collectionView.contentOffset.x / collectionView.bounds.width).rounded())
        pageTurnRestingIndex = min(max(currentIndex, 0), max(inputs.itemCount - 1, 0))
    }

    private func applyPageTurnVisuals(in collectionView: UICollectionView, inputs: ReaderPagedPagingInputs) {
        guard let metrics = ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: collectionView.contentOffset.x,
            pageWidth: collectionView.bounds.width,
            pageCount: inputs.itemCount,
            restingPageIndex: pageTurnRestingIndex ?? itemIndex(for: inputs.selectionIndex, inputs: inputs),
            cornerRadius: ReaderPagedPageTurnCornerRadius.radius(for: collectionView.window?.screen)
        ) else {
            resetPageTurnVisuals(in: collectionView, inputs: inputs)
            return
        }
        collectionView.backgroundColor = inputs.pageTurnBackgroundColor(
            collectionView.traitCollection,
            metrics.overlayAlpha
        )

        for case let cell as ReaderPagedPageTurnCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else {
                cell.resetPageTurnVisuals()
                continue
            }
            if indexPath.item == metrics.maskedPageIndex {
                cell.applyPageTurnVisuals(
                    overlayAlpha: metrics.overlayAlpha,
                    cornerRadius: 0
                )
            } else if indexPath.item == metrics.roundedPageIndex {
                cell.applyPageTurnVisuals(
                    overlayAlpha: 0,
                    cornerRadius: metrics.cornerRadius
                )
            } else {
                cell.resetPageTurnVisuals()
            }
        }
    }

    private func endPageTurnVisuals(in collectionView: UICollectionView, inputs: ReaderPagedPagingInputs) {
        pageTurnRestingIndex = nil
        resetPageTurnVisuals(in: collectionView, inputs: inputs)
    }

    private func resetPageTurnVisuals(in collectionView: UICollectionView, inputs: ReaderPagedPagingInputs) {
        collectionView.backgroundColor = inputs.pageTurnRestingBackgroundColor(collectionView.traitCollection)
        for case let cell as ReaderPagedPageTurnCell in collectionView.visibleCells {
            cell.resetPageTurnVisuals()
        }
    }

    private func itemIndex(for selectionIndex: Int, inputs: ReaderPagedPagingInputs) -> Int {
        min(max(inputs.itemIndexForSelectionIndex(selectionIndex), 0), max(inputs.itemCount - 1, 0))
    }

    private func selectionIndex(forItemIndex itemIndex: Int, inputs: ReaderPagedPagingInputs) -> Int {
        clampedSelectionIndex(inputs.selectionIndexForItemIndex(itemIndex), inputs: inputs)
    }

    private func clampedSelectionIndex(_ selectionIndex: Int, inputs: ReaderPagedPagingInputs) -> Int {
        min(max(selectionIndex, 0), max(inputs.itemCount - 1, 0))
    }

    private func matchingScrollAnimationRequest(
        inputs: ReaderPagedPagingInputs
    ) -> ReaderPagedScrollAnimationRequest? {
        guard let request = inputs.scrollAnimationRequest,
              request.id != consumedScrollAnimationRequestID,
              request.pagerIdentity == inputs.pagerIdentity,
              request.selectionIndex == inputs.selectionIndex else {
            return nil
        }
        return request
    }

    private func consumeScrollAnimationRequest(
        _ request: ReaderPagedScrollAnimationRequest,
        inputs: ReaderPagedPagingInputs
    ) {
        consumedScrollAnimationRequestID = request.id
        let onScrollAnimationRequestConsumed = inputs.onScrollAnimationRequestConsumed
        callbackScheduler.publish {
            onScrollAnimationRequestConsumed(request)
        }
    }
}
#endif
