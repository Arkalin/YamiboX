import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedPageCurlReaderViewport: UIViewControllerRepresentable {
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

        let containerViewController = MangaPagedPageCurlContainerViewController(pageViewController: pageViewController)
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
        context.coordinator.zoom.updatePageCurlSpreadZoomAvailability(in: containerViewController, animated: false)
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
            context.coordinator.zoom.updatePageCurlSpreadZoomAvailability(in: containerViewController, animated: true)
        }
        let gestures = context.coordinator.gestures
        controlPageTurnBridge.attemptEdgeReveal = { [weak gestures, weak containerViewController] delta in
            guard let gestures, let containerViewController else { return false }
            return gestures.attemptControlPageTurnEdgeReveal(delta: delta, in: containerViewController)
        }
    }
}
#endif
