import SwiftUI
import YamiboXCore

struct NovelReaderPagedPageCurlLeaf: Hashable {
    enum Kind: Hashable {
        case surface(Int)
        case back(Int)
        case blank
    }

    var index: Int
    var kind: Kind
    var selectionIndex: Int

    var surfaceIndex: Int? {
        guard case let .surface(surfaceIndex) = kind else { return nil }
        return surfaceIndex
    }

    var backSurfaceIndex: Int? {
        guard case let .back(surfaceIndex) = kind else { return nil }
        return surfaceIndex
    }

    var isBack: Bool { backSurfaceIndex != nil }
}

struct NovelReaderPagedPageCurlSequence: Equatable {
    var leaves: [NovelReaderPagedPageCurlLeaf]
    var usesTwoPageSpread: Bool

    init(
        surfaces: [NovelReaderSurface],
        spreads: [NovelReaderPresentationSpread],
        usesTwoPageSpread: Bool,
        pageTurnDirection: ReaderPageTurnDirection = .leftToRight
    ) {
        self.usesTwoPageSpread = usesTwoPageSpread
        if usesTwoPageSpread {
            let leafGroups = spreads.map { spread in
                [
                    NovelReaderPagedPageCurlLeaf(
                        index: 0,
                        kind: .surface(spread.leftSurfaceIndex),
                        selectionIndex: spread.index
                    ),
                    NovelReaderPagedPageCurlLeaf(
                        index: 0,
                        kind: spread.rightSurfaceIndex.map(NovelReaderPagedPageCurlLeaf.Kind.surface) ?? .blank,
                        selectionIndex: spread.index
                    ),
                ]
            }
            let orderedLeaves = Self.physicalBookOrder(
                leafGroups: leafGroups,
                pageTurnDirection: pageTurnDirection
            )
            leaves = orderedLeaves.isEmpty ? Self.emptySpreadLeaves : Self.indexedLeaves(from: orderedLeaves)
        } else {
            let leafGroups = surfaces.indices.map { index in
                [
                    NovelReaderPagedPageCurlLeaf(
                        index: 0,
                        kind: .surface(index),
                        selectionIndex: index
                    ),
                    NovelReaderPagedPageCurlLeaf(index: 0, kind: .back(index), selectionIndex: index),
                ]
            }
            let orderedLeaves = Self.physicalBookOrder(
                leafGroups: leafGroups,
                pageTurnDirection: pageTurnDirection
            )
            leaves = orderedLeaves.isEmpty ? Self.emptySingleLeaves : Self.indexedLeaves(from: orderedLeaves)
        }
    }

    private static var emptySingleLeaves: [NovelReaderPagedPageCurlLeaf] {
        [
            NovelReaderPagedPageCurlLeaf(index: 0, kind: .blank, selectionIndex: 0),
            NovelReaderPagedPageCurlLeaf(index: 1, kind: .back(0), selectionIndex: 0)
        ]
    }

    private static var emptySpreadLeaves: [NovelReaderPagedPageCurlLeaf] {
        [
            NovelReaderPagedPageCurlLeaf(index: 0, kind: .blank, selectionIndex: 0),
            NovelReaderPagedPageCurlLeaf(index: 1, kind: .blank, selectionIndex: 0)
        ]
    }

    var pageCount: Int {
        leaves.count / 2
    }

    func leafIndexes(forSelectionIndex selectionIndex: Int) -> [Int] {
        guard !leaves.isEmpty else { return [] }
        let clampedSelection = min(max(selectionIndex, 0), max(pageCount - 1, 0))
        let indexes = leaves
            .filter { $0.selectionIndex == clampedSelection }
            .map(\.index)
        if indexes.isEmpty {
            return [0, 1].filter { leaves.indices.contains($0) }
        }
        return indexes
    }

    func selectionIndex(forLeafIndexes leafIndexes: [Int]) -> Int? {
        leafIndexes
            .compactMap { index -> Int? in
                guard leaves.indices.contains(index), !leaves[index].isBack else { return nil }
                return leaves[index].selectionIndex
            }
            .min()
    }

    func firstLeafIndex(forSelectionIndex selectionIndex: Int) -> Int? {
        leafIndexes(forSelectionIndex: selectionIndex).first
    }

    private static func physicalBookOrder(
        leafGroups: [[NovelReaderPagedPageCurlLeaf]],
        pageTurnDirection: ReaderPageTurnDirection
    ) -> [NovelReaderPagedPageCurlLeaf] {
        switch pageTurnDirection {
        case .leftToRight:
            leafGroups.flatMap { $0 }
        case .rightToLeft:
            leafGroups.reversed().flatMap { $0 }
        }
    }

    private static func indexedLeaves(from leaves: [NovelReaderPagedPageCurlLeaf]) -> [NovelReaderPagedPageCurlLeaf] {
        leaves.enumerated().map { index, leaf in
            NovelReaderPagedPageCurlLeaf(
                index: index,
                kind: leaf.kind,
                selectionIndex: leaf.selectionIndex
            )
        }
    }
}

#if os(iOS)
import UIKit

struct NovelReaderPagedPageCurlViewport: UIViewControllerRepresentable {
    let spreads: [NovelReaderPresentationSpread]
    let surfaces: [NovelReaderSurface]
    let settings: NovelReaderAppearanceSettings
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let selectionIndex: Int
    let usesTwoPageSpread: Bool
    let pagerIdentity: ReaderPagedPagerIdentity
    let scrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    let displayReferenceProvider: @MainActor (NovelReaderSurfaceIdentity) -> NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let searchHighlightController: NovelReaderSearchHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let isChromeVisible: Bool
    let canBoundaryPageTurn: (Int) -> Bool
    let onSelectionChange: (Int) -> Void
    let onBoundaryPageTurn: (Int) -> Void
    var onBoundaryPageTurnRejected: (Int) -> Void = { _ in }
    let onPageTapZone: (ReaderPagedTapZone) -> Void
    let onScrollAnimationRequestConsumed: (ReaderPagedScrollAnimationRequest) -> Void
    let onChromeVisibleImageTap: () -> Void
    let onImageTap: (URL, String?) -> Void
    let onImageLongPress: (NovelImageLikeAnchor, URL, String?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.yamiboImagePipeline) private var imagePipeline

    private var pageBackgroundColor: UIColor {
        readerThemeUIColor(for: settings.backgroundStyle, colorScheme: colorScheme)
    }

    private var sequence: NovelReaderPagedPageCurlSequence {
        NovelReaderPagedPageCurlSequence(
            surfaces: surfaces,
            spreads: spreads,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: settings.pageTurnDirection
        )
    }

    private var contentIdentity: NovelReaderPagedSpreadViewportContentIdentity {
        NovelReaderPagedSpreadViewportContentIdentity(
            spreads: spreads,
            content: NovelReaderPagedViewportContentIdentity(
                surfaces: surfaces,
                settings: settings,
                refererURL: refererURL,
                topInset: topInset,
                bottomInset: bottomInset
            )
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let spineLocation: UIPageViewController.SpineLocation = sequence.usesTwoPageSpread ? .mid : .min
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: spineLocation.rawValue]
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = pageBackgroundColor
        pageViewController.view.isOpaque = true
        pageViewController.view.layer.speed = ReaderPagedPageCurlTransition.animationSpeed

        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = context.coordinator
        pageViewController.view.addGestureRecognizer(tapRecognizer)

        let longPressRecognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressRecognizer.minimumPressDuration = 0.45
        longPressRecognizer.cancelsTouchesInView = false
        longPressRecognizer.delegate = context.coordinator
        pageViewController.view.addGestureRecognizer(longPressRecognizer)

        let boundaryPageTurnPanRecognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleBoundaryPageTurnPan(_:))
        )
        boundaryPageTurnPanRecognizer.delegate = context.coordinator
        pageViewController.view.addGestureRecognizer(boundaryPageTurnPanRecognizer)
        context.coordinator.boundaryPageTurnPanRecognizer = boundaryPageTurnPanRecognizer

        context.coordinator.applyPageBackground(to: pageViewController)
        context.coordinator.configureGestures(in: pageViewController)
        context.coordinator.configureSpine(in: pageViewController)
        context.coordinator.setCurrentSelection(in: pageViewController, animated: false)
        selectionController?.configure(mode: .paged)
        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        selectionController?.configure(mode: .paged)
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.update(pageViewController)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: NovelReaderPagedPageCurlViewport
        let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
        private var contentIdentity: NovelReaderPagedSpreadViewportContentIdentity?
        private var imagePipeline: YamiboUIImagePipeline?
        private var consumedScrollAnimationRequestID: UUID?
        private var currentSelectionIndex: Int?
        weak var boundaryPageTurnPanRecognizer: UIPanGestureRecognizer?
        private var transitionParent: NovelReaderPagedPageCurlViewport?
        private var needsDeferredUpdate = false
        private var renderedColorScheme: ColorScheme
        private let controllers = NSHashTable<NovelReaderPagedPageCurlHostingController>.weakObjects()
        private var lightingDisplayLink: CADisplayLink?

        private var renderingParent: NovelReaderPagedPageCurlViewport { transitionParent ?? parent }

        init(parent: NovelReaderPagedPageCurlViewport) {
            self.parent = parent
            renderedColorScheme = parent.colorScheme
            contentIdentity = parent.contentIdentity
            imagePipeline = parent.imagePipeline
        }

        deinit {
            MainActor.assumeIsolated {
                lightingDisplayLink?.invalidate()
            }
        }

        func update(
            _ pageViewController: UIPageViewController,
            selectionIndex: Int? = nil
        ) {
            guard transitionParent == nil else {
                needsDeferredUpdate = true
                return
            }
            let nextContentIdentity = parent.contentIdentity
            let didChangeContentIdentity = contentIdentity != nextContentIdentity || imagePipeline !== parent.imagePipeline
            contentIdentity = nextContentIdentity
            imagePipeline = parent.imagePipeline
            configureGestures(in: pageViewController)
            configureSpine(in: pageViewController)
            applyPageBackground(to: pageViewController)

            if let animationRequest = matchingScrollAnimationRequest() {
                setCurrentSelection(in: pageViewController, animated: true) { [weak self] in
                    self?.consumeScrollAnimationRequest(animationRequest)
                }
                return
            }

            let targetSelectionIndex = selectionIndex ?? parent.selectionIndex
            if didChangeContentIdentity || currentSelectionIndex != targetSelectionIndex {
                setCurrentSelection(in: pageViewController, animated: false, selectionIndex: targetSelectionIndex)
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let pageController = viewController as? NovelReaderPagedPageCurlHostingController else {
                return nil
            }
            return controller(forLeafIndex: pageController.leaf.index - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let pageController = viewController as? NovelReaderPagedPageCurlHostingController else {
                return nil
            }
            return controller(forLeafIndex: pageController.leaf.index + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            transitionParent = parent
            startLightingRefresh(in: pageViewController)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            configureSpine(in: pageViewController)
            setCurrentSelection(in: pageViewController, animated: false)
            return parent.sequence.usesTwoPageSpread ? .mid : .min
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            if completed {
                publishSelection(from: pageViewController)
            }
            finishTransition(in: pageViewController)
        }

        @objc
        func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let containerView = recognizer.view else {
                return
            }
            let location = recognizer.location(in: containerView)
            if parent.selectionController?.hasSelection == true {
                parent.selectionController?.clearSelection()
                return
            }
            if let imageView = containerView.firstDescendant(
                ofType: NovelReaderVerticalViewportImageView.self,
                containing: location
            ) {
                let imageLocation = containerView.convert(location, to: imageView)
                handleImageTap(imageView, at: imageLocation)
                return
            }

            let zone = ReaderPagedTapZone.zone(for: location, in: containerView.bounds)
            let directionalZone = parent.settings.pageTurnDirection.directionalTapZone(for: zone)
            let onPageTapZone = parent.onPageTapZone
            callbackScheduler.publish {
                onPageTapZone(directionalZone)
            }
        }

        @objc
        func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let containerView = recognizer.view else {
                return
            }
            let location = recognizer.location(in: containerView)
            guard let imageView = containerView.firstDescendant(
                ofType: NovelReaderVerticalViewportImageView.self,
                containing: location
            ), let payload = imageView.imageTapPayloadIfHit(
                at: containerView.convert(location, to: imageView)
            ), let anchor = novelImageLikeAnchor(forImageURL: payload.url, in: parent.surfaces) else {
                return
            }
            let onImageLongPress = parent.onImageLongPress
            callbackScheduler.publish {
                onImageLongPress(anchor, payload.url, payload.title)
            }
        }

        @objc
        func handleBoundaryPageTurnPan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended,
                  !parent.isChromeVisible,
                  let view = recognizer.view else {
                return
            }
            guard let delta = ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: parent.selectionIndex,
                itemCount: parent.sequence.pageCount,
                translation: recognizer.translation(in: view),
                velocity: recognizer.velocity(in: view),
                viewportWidth: view.bounds.width,
                horizontalNavigationDirection: parent.settings.pageTurnDirection.horizontalNavigationDirection
            ) else {
                return
            }
            let onBoundaryPageTurn = parent.canBoundaryPageTurn(delta)
                ? parent.onBoundaryPageTurn : parent.onBoundaryPageTurnRejected
            callbackScheduler.publish {
                onBoundaryPageTurn(delta)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === boundaryPageTurnPanRecognizer ||
                otherGestureRecognizer === boundaryPageTurnPanRecognizer {
                return true
            }
            return otherGestureRecognizer.view?.isDescendant(ofType: NovelReaderVerticalViewportImageView.self) == true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === boundaryPageTurnPanRecognizer,
                  let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  !parent.isChromeVisible,
                  let view = panRecognizer.view else {
                return true
            }
            let velocity = panRecognizer.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            let physicalDelta = velocity.x < 0 ? 1 : -1
            let delta = ReaderPagedBoundaryPageTurn.directionalDelta(
                physicalDelta,
                direction: parent.settings.pageTurnDirection.horizontalNavigationDirection
            )
            let targetItem = parent.selectionIndex + delta
            guard targetItem < 0 || targetItem >= parent.sequence.pageCount else { return true }
            return parent.sequence.pageCount > 0
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.view?.isDescendant(ofType: UIControl.self) != true
        }

        func configureSpine(in pageViewController: UIPageViewController) {
            pageViewController.isDoubleSided = true
        }

        func configureGestures(in pageViewController: UIPageViewController) {
            for recognizer in pageViewController.gestureRecognizers {
                if recognizer is UITapGestureRecognizer {
                    recognizer.isEnabled = false
                } else if recognizer is UIPanGestureRecognizer {
                    recognizer.isEnabled = !parent.isChromeVisible
                }
            }
            boundaryPageTurnPanRecognizer?.isEnabled = !parent.isChromeVisible
        }

        func setCurrentSelection(
            in pageViewController: UIPageViewController,
            animated: Bool,
            selectionIndex: Int? = nil,
            completion: (() -> Void)? = nil
        ) {
            let targetSelectionIndex = selectionIndex ?? parent.selectionIndex
            let leafIndexes = parent.sequence.leafIndexes(forSelectionIndex: targetSelectionIndex)
            let direction: UIPageViewController.NavigationDirection = {
                guard let currentSelectionIndex,
                      let currentLeafIndex = parent.sequence.firstLeafIndex(forSelectionIndex: currentSelectionIndex),
                      let targetLeafIndex = parent.sequence.firstLeafIndex(forSelectionIndex: targetSelectionIndex) else {
                    return .forward
                }
                return targetLeafIndex >= currentLeafIndex ? .forward : .reverse
            }()

            // Nonanimated single-page placement accepts only the visible front.
            // Forward curls expose the departing sheet's back; reverse curls expose the arriving sheet's back.
            var displayedLeafIndexes = parent.sequence.usesTwoPageSpread || animated
                ? leafIndexes : Array(leafIndexes.prefix(1))
            if animated, !parent.sequence.usesTwoPageSpread, direction == .forward,
               let currentSelectionIndex,
               let backIndex = parent.sequence.leafIndexes(forSelectionIndex: currentSelectionIndex).last,
               displayedLeafIndexes.count == 2 {
                displayedLeafIndexes[1] = backIndex
            }
            let controllers = displayedLeafIndexes.compactMap(controller(forLeafIndex:))
            guard !controllers.isEmpty else {
                currentSelectionIndex = nil
                completion?()
                return
            }

            if animated {
                transitionParent = parent
                startLightingRefresh(in: pageViewController)
            }
            pageViewController.setViewControllers(
                controllers,
                direction: direction,
                animated: animated
            ) { [weak self] completed in
                guard let self else { return }
                if !animated || completed {
                    self.currentSelectionIndex = targetSelectionIndex
                }
                completion?()
                if animated {
                    self.finishTransition(in: pageViewController)
                }
            }
            if !animated {
                currentSelectionIndex = targetSelectionIndex
            } else {
                NovelReaderPageCurlLighting.apply(to: pageViewController.view.layer)
            }
        }

        private func startLightingRefresh(in pageViewController: UIPageViewController) {
            NovelReaderPageCurlLighting.apply(to: pageViewController.view.layer)
            guard lightingDisplayLink == nil else { return }
            let target = NovelReaderPageCurlLighting(view: pageViewController.view)
            let displayLink = CADisplayLink(target: target, selector: #selector(NovelReaderPageCurlLighting.refresh(_:)))
            displayLink.add(to: .main, forMode: .common)
            lightingDisplayLink = displayLink
        }

        private func controller(forLeafIndex leafIndex: Int) -> UIViewController? {
            let parent = renderingParent
            guard parent.sequence.leaves.indices.contains(leafIndex) else { return nil }
            let leaf = parent.sequence.leaves[leafIndex]
            let controller = NovelReaderPagedPageCurlHostingController(
                leaf: leaf,
                rootView: NovelReaderPagedPageCurlLeafView(
                    leaf: leaf,
                    surfaces: parent.surfaces,
                    settings: parent.settings,
                    colorScheme: renderedColorScheme,
                    refererURL: parent.refererURL,
                    offlineScope: parent.offlineScope,
                    imagePipeline: parent.imagePipeline,
                    topInset: parent.topInset,
                    bottomInset: parent.bottomInset,
                    displayReferenceProvider: parent.displayReferenceProvider,
                    selectionController: parent.selectionController,
                    likeHighlightController: parent.likeHighlightController,
                    searchHighlightController: parent.searchHighlightController,
                    likedImageAnchors: parent.likedImageAnchors,
                    onImageTap: parent.onImageTap
                )
            )
            controllers.add(controller)
            return controller
        }

        func applyPageBackground(to pageViewController: UIPageViewController) {
            guard transitionParent == nil else { return }
            renderedColorScheme = parent.colorScheme
            let pageBackgroundColor = parent.pageBackgroundColor
            pageViewController.view.backgroundColor = pageBackgroundColor
            pageViewController.view.isOpaque = true
            for controller in controllers.allObjects {
                controller.applyAppearance(
                    backgroundStyle: parent.settings.backgroundStyle,
                    colorScheme: renderedColorScheme
                )
            }
        }

        private func finishTransition(in pageViewController: UIPageViewController) {
            lightingDisplayLink?.invalidate()
            lightingDisplayLink = nil
            let previousRequestedSelection = transitionParent?.selectionIndex
            transitionParent = nil
            if needsDeferredUpdate {
                needsDeferredUpdate = false
                // A theme-only update must not restore the pre-gesture reading position.
                let selection = parent.selectionIndex == previousRequestedSelection
                    ? currentSelectionIndex : parent.selectionIndex
                update(pageViewController, selectionIndex: selection)
            } else {
                applyPageBackground(to: pageViewController)
            }
        }

        private func publishSelection(from pageViewController: UIPageViewController) {
            let leafIndexes = pageViewController.viewControllers?
                .compactMap { ($0 as? NovelReaderPagedPageCurlHostingController)?.leaf.index } ?? []
            guard let selectionIndex = renderingParent.sequence.selectionIndex(forLeafIndexes: leafIndexes) else { return }
            currentSelectionIndex = selectionIndex
            guard selectionIndex != parent.selectionIndex else { return }
            let onSelectionChange = parent.onSelectionChange
            callbackScheduler.publish {
                onSelectionChange(selectionIndex)
            }
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

        private func matchingScrollAnimationRequest() -> ReaderPagedScrollAnimationRequest? {
            guard let request = parent.scrollAnimationRequest,
                  request.id != consumedScrollAnimationRequestID,
                  request.pagerIdentity == parent.pagerIdentity,
                  request.selectionIndex == parent.selectionIndex else {
                return nil
            }
            return request
        }

        private func consumeScrollAnimationRequest(_ request: ReaderPagedScrollAnimationRequest) {
            consumedScrollAnimationRequestID = request.id
            let onScrollAnimationRequestConsumed = parent.onScrollAnimationRequestConsumed
            callbackScheduler.publish {
                onScrollAnimationRequestConsumed(request)
            }
        }
    }
}

// UIKit has no public control for the curl's additive back lighting. Keep this
// compatibility adjustment separate from page content, geometry, and shadow colors.
@MainActor
private final class NovelReaderPageCurlLighting: NSObject {
    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
    }

    @objc func refresh(_ displayLink: CADisplayLink) {
        guard let view else {
            displayLink.invalidate()
            return
        }
        Self.apply(to: view.layer)
    }

    static func apply(to layer: CALayer) {
        for key in ["filters", "backgroundFilters"] {
            for filter in layer.value(forKey: key) as? [NSObject] ?? []
                where String(describing: filter) == "pageCurl" {
                filter.setValue(UIColor.clear.cgColor, forKey: "inputBackColor0")
                filter.setValue(UIColor.clear.cgColor, forKey: "inputBackColor1")
            }
        }
        // UIKit can add new filters after a gesture starts, including when reversing.
        for sublayer in layer.sublayers ?? [] {
            apply(to: sublayer)
        }
    }
}

private final class NovelReaderPagedPageCurlHostingController: UIHostingController<NovelReaderPagedPageCurlLeafView> {
    let leaf: NovelReaderPagedPageCurlLeaf

    init(
        leaf: NovelReaderPagedPageCurlLeaf,
        rootView: NovelReaderPagedPageCurlLeafView
    ) {
        self.leaf = leaf
        super.init(rootView: rootView)
        view.backgroundColor = readerThemeUIColor(for: rootView.settings.backgroundStyle, colorScheme: rootView.colorScheme)
        view.isOpaque = true
    }

    @MainActor @preconcurrency
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyAppearance(backgroundStyle: ReaderBackgroundStyle, colorScheme: ColorScheme) {
        if rootView.settings.backgroundStyle != backgroundStyle || rootView.colorScheme != colorScheme {
            var updatedRoot = rootView
            updatedRoot.settings.backgroundStyle = backgroundStyle
            updatedRoot.colorScheme = colorScheme
            rootView = updatedRoot
        }
        view.backgroundColor = readerThemeUIColor(for: backgroundStyle, colorScheme: colorScheme)
        view.isOpaque = true
    }
}

private struct NovelReaderPagedPageCurlLeafView: View {
    let leaf: NovelReaderPagedPageCurlLeaf
    let surfaces: [NovelReaderSurface]
    var settings: NovelReaderAppearanceSettings
    var colorScheme: ColorScheme
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let imagePipeline: YamiboUIImagePipeline?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let displayReferenceProvider: @MainActor (NovelReaderSurfaceIdentity) -> NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let searchHighlightController: NovelReaderSearchHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let onImageTap: (URL, String?) -> Void

    var body: some View {
        NovelReaderPagedPageSurfaceContainer(settings: settings) {
            if let surfaceIndex = leaf.surfaceIndex ?? leaf.backSurfaceIndex,
               !leaf.isBack || surfaces.indices.contains(surfaceIndex) {
                let surface = surfaces.indices.contains(surfaceIndex) ? surfaces[surfaceIndex] : nil
                NovelReaderViewportSurfaceContent(
                    surface: surface,
                    displayReference: surface.flatMap { displayReferenceProvider($0.identity) },
                    selectionController: leaf.isBack ? nil : selectionController,
                    likeHighlightController: leaf.isBack ? nil : likeHighlightController,
                    searchHighlightController: leaf.isBack ? nil : searchHighlightController,
                    likedImageAnchors: leaf.isBack ? [] : likedImageAnchors,
                    fallbackDocumentView: surface?.documentView,
                    fallbackSurfaceIndex: surfaceIndex,
                    settings: settings,
                    refererURL: refererURL,
                    offlineScope: offlineScope,
                    onImageTap: onImageTap
                )
                .padding(.horizontal, settings.horizontalPadding)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Show the ink through the paper without making the themed sheet translucent.
                .scaleEffect(x: leaf.isBack ? -1 : 1, y: 1)
                .opacity(leaf.isBack ? 0.18 : 1)
                .allowsHitTesting(!leaf.isBack)
                .accessibilityHidden(leaf.isBack)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(NovelReaderPagedHostingTopSafeAreaModifier())
        .environment(\.colorScheme, colorScheme)
        .environment(\.yamiboImagePipeline, imagePipeline)
    }
}
#endif
