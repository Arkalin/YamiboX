import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedPageCurlReaderViewport: UIViewControllerRepresentable {
    var attachedInformation = ReaderAttachedInformationConfiguration()
    static func dismantleUIViewController(_ controller: MangaPagedPageCurlContainerViewController, coordinator: MangaPagedPageCurlCoordinator) {
        coordinator.stopImagePrefetch()
        coordinator.invalidatePageCurlTransitions()
        coordinator.gestures.detach()
        coordinator.interactionRuntime.reset()
        coordinator.zoom.detach(from: controller)
    }
    let plan: MangaPagedReadingPlan
    let viewportPlacement: MangaNovelReaderViewportPlacement?
    let settings: MangaReaderSettings
    let imageLoader: MangaReaderPageImageLoader
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let likedPageIDs: Set<String>
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
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

    var sequence: MangaPagedPageCurlSequence {
        MangaPagedPageCurlSequence(plan: plan)
    }

    var selectionIndex: Int {
        MangaPagedPageCurlSelectionResolver.currentSelectionIndex(plan: plan)
    }

    private var contentIdentity: MangaPagedReaderContentIdentity {
        MangaPagedReaderContentIdentity(
            spreadIDs: plan.spreads.map(\.id),
            pageScaleMode: effectivePageScaleMode,
            pagedTurnStyle: settings.pagedTurnStyle,
            pageTurnDirection: settings.pageTurnDirection,
            pageEdgeFillStyle: settings.pageEdgeFillStyle,
            colorScheme: colorScheme
        )
    }

    func makeCoordinator() -> MangaPagedPageCurlCoordinator {
        MangaPagedPageCurlCoordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> MangaPagedPageCurlContainerViewController {
        let spineLocation: UIPageViewController.SpineLocation = sequence.usesTwoPageSpread ? .mid : .min
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
    }
}
#endif
