import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedPageCurlReaderViewport: UIViewControllerRepresentable {
    @Environment(\.mangaViewportHandoff) var handoff
    @Environment(\.readerRemoteInput) var remoteInput
    @Environment(\.readerDeviceInteraction) var deviceInteraction
    var attachedInformation = ReaderAttachedInformationConfiguration()
    static func dismantleUIViewController(_ controller: MangaPagedPageCurlContainerViewController, coordinator: MangaPagedPageCurlCoordinator) {
        coordinator.stopImagePrefetch()
        coordinator.invalidatePageCurlTransitions()
        coordinator.gestures.detach()
        coordinator.interactionRuntime.reset()
        coordinator.zoom.detach(from: controller)
    }
    let plan: MangaPagedReadingPlan
    let sequence: MangaPagedPageCurlSequence
    let viewportPlacement: MangaNovelReaderViewportPlacement?
    let settings: MangaReaderSettings
    let imageLoader: MangaReaderPageImageLoader
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let likedPageIDs: Set<String>
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
    let pagedZoom: MangaPagedZoomSession
    let onCurrentPageChange: (Int) -> Void
    let canBoundaryPageTurn: (Int) -> Bool
    let onBoundaryPageTurn: (Int) -> Void
    var onBoundaryPageTurnRejected: (Int) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var pageEdgeFillColor: UIColor {
        settings.pageEdgeFillStyle.uiColor(for: colorScheme)
    }

    var effectivePageScaleMode: MangaPageScaleMode {
        MangaPagedLayoutPolicy.effectivePageScaleMode(
            settings: settings,
            usesTwoPageSpread: plan.usesTwoPageSpread
        )
    }

    var selectionIndex: Int {
        MangaPagedPageCurlSelectionResolver.currentSelectionIndex(plan: plan)
    }

    private var contentIdentity: MangaPagedReaderContentIdentity {
        MangaPagedReaderContentIdentity(
            spreadIDs: plan.spreadIDs,
            pageScaleMode: effectivePageScaleMode,
            pageTurnDirection: settings.pageTurnDirection,
            pageEdgeFillStyle: settings.pageEdgeFillStyle,
            colorScheme: colorScheme
        )
    }

    func makeCoordinator() -> MangaPagedPageCurlCoordinator {
        MangaPagedPageCurlCoordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> MangaPagedPageCurlContainerViewController {
        let spineLocation = ReaderPagedPageCurlTransition.spineLocation(
            usesTwoPageSpread: sequence.usesTwoPageSpread,
            direction: settings.pageTurnDirection.horizontalNavigationDirection
        )
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: spineLocation.rawValue]
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = pageEdgeFillColor
        pageViewController.view.isOpaque = true
        pageViewController.view.layer.speed = ReaderPagedPageCurlTransition.animationSpeed

        let containerViewController = MangaPagedPageCurlContainerViewController(
            pageViewController: pageViewController, informationState: context.coordinator.informationState)
        let coordinator = context.coordinator
        containerViewController.onLayoutSubviews = { [weak coordinator, weak containerViewController] in
            guard let containerViewController else { return }
            coordinator?.zoom.pageCurlContainerDidLayout(containerViewController)
        }

        context.coordinator.gestures.configureContainerGestures(in: containerViewController)
        context.coordinator.gestures.configureGestures(in: pageViewController)
        _ = context.coordinator.configureSpine(in: pageViewController)
        context.coordinator.applyPageBackground(to: containerViewController)
        context.coordinator.setCurrentSelection(in: pageViewController, animated: false)
        context.coordinator.zoom.updatePageCurlSpreadZoomAvailability(in: containerViewController)
        return containerViewController
    }

    func updateUIViewController(_ containerViewController: MangaPagedPageCurlContainerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.callbackScheduler.performViewUpdate {
            context.coordinator.update(
                containerViewController,
                contentIdentity: contentIdentity
            )
            context.coordinator.applyPageBackground(to: containerViewController)
            context.coordinator.zoom.updatePageCurlSpreadZoomAvailability(in: containerViewController)
        }
        let gestures = context.coordinator.gestures
        controlPageTurnBridge.route = { [weak gestures, weak containerViewController] step in
            guard let gestures, let containerViewController else { return }
            gestures.routeControl(step, in: containerViewController)
        }
        controlPageTurnBridge.pagedSurface = { [weak gestures] in gestures?.currentSurface }
        let coordinator = context.coordinator
        controlPageTurnBridge.capturePosition = { [weak coordinator] in
            guard let coordinator, let spread = coordinator.parent.plan.spread(at: coordinator.selectionIndex) else { return nil }
            let plan = coordinator.parent.plan
            let retainedIndex = plan.currentPageIndex.flatMap { spread.containsPage(at: $0) ? $0 : nil }
            let fallback = retainedIndex.map { plan.pages[$0] } ?? spread.preferredPage
            let focus = coordinator.gestures.currentSurface?.pageFocus
            let page = [spread.leftPage, spread.rightPage].compactMap { $0 }.first { $0.id == focus?.pageID } ?? fallback
            return .init(page: page, placement: coordinator.parent.viewportPlacement, focus: focus)
        }
    }
}
#endif
