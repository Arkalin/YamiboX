import SwiftUI
import YamiboXCore

/// Owns scroll-view wiring; the root receives only user interaction events.
struct NovelReaderVerticalContent: View {
    let model: NovelReaderViewModel
    let layout: NovelReaderLayout
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isPadDevice: Bool
    let verticalRestore: NovelReaderVerticalRestoreCoordinator
    let verticalScrollCoordinator: NovelReaderVerticalScrollCoordinator
    let viewport: ReaderViewportLifetime
    let annotations: NovelReaderAnnotationCoordinator
    let searchHighlightController: NovelReaderSearchHighlightController
    let verticalTapSuppression: NovelReaderVerticalTapSuppression
    let onBoundaryPullRelease: (NovelReaderVerticalBoundaryDirection, @escaping () -> Bool) -> Void
    let updateVerticalBoundaryPullState: (NovelReaderVerticalBoundaryPullState) -> Void
    let handleVerticalTap: () -> Void
    let onOpenImage: (URL, String?) -> Void

    var body: some View {
        var displaySettings = model.settings
        displaySettings.horizontalPadding = layout.novelTextBoxLayout(
            settings: model.settings, usesPadPresentation: isPadDevice
        ).contentInsets.leading
        return NovelReaderVerticalViewportScrollView(
            structureID: model.presentationStructure?.id,
            surfaces: model.novelReaderSurfaces,
            settings: displaySettings,
            refererURL: model.forumURL,
            offlineScope: model.inlineImageOfflineScope,
            topInset: topInset,
            bottomInset: bottomInset,
            scrollRequest: verticalRestore.verticalScrollRequest,
            displayReferenceProvider: { surfaceIdentity in
                model.novelTextViewportDisplayReference(for: surfaceIdentity)
            },
            selectionController: annotations.selectionController,
            likeHighlightController: annotations.highlightController,
            searchHighlightController: searchHighlightController,
            likedImageAnchors: annotations.likedImageAnchors,
            onVisibleSurfaceIdentitiesChange: { surfaceIdentities in
                guard viewport.acceptsGeometry else { return }
                model.updateNovelTextViewportVisibleSurfaceIdentities(surfaceIdentities)
            },
            onScrollRequestHandled: { request in
                verticalRestore.handleScrollRequestHandled(
                    request,
                    model: model,
                    scrollCoordinator: verticalScrollCoordinator
                )
            },
            onScrollViewReady: { scrollView, settle in
                guard viewport.acceptsGeometry else { return }
                verticalScrollCoordinator.attach(scrollView: scrollView)
                verticalScrollCoordinator.onSettle = settle
                verticalScrollCoordinator.onDragStart = {
                    verticalRestore.cancelVerticalRestoreForUserScroll()
                    verticalTapSuppression.until = CACurrentMediaTime() + 0.5
                }
                verticalScrollCoordinator.onBoundaryPullRelease = onBoundaryPullRelease
                verticalScrollCoordinator.onViewportMetricsChange = {
                    Task { @MainActor in
                        verticalRestore.tryAdvanceVerticalRestore(
                            model: model,
                            scrollCoordinator: verticalScrollCoordinator
                        )
                        verticalRestore.applyVerticalViewportPositionUpdate(
                            for: .viewportGeometryChanged,
                            model: model
                        )
                    }
                }
                verticalScrollCoordinator.onBoundaryPullStateChange = { state in
                    Task { @MainActor in
                        updateVerticalBoundaryPullState(state)
                    }
                }
            },
            onSurfaceFramesChange: { frames in
                verticalRestore.handleSurfaceFramesChange(
                    frames,
                    model: model,
                    scrollCoordinator: verticalScrollCoordinator
                )
            },
            onViewportSampleChange: { sample in
                verticalRestore.handleViewportSampleChange(sample, model: model)
            },
            onViewportChange: {
                verticalRestore.applyVerticalViewportPositionUpdate(
                    for: .viewportGeometryChanged,
                    model: model
                )
            },
            onScrollSettled: {
                guard viewport.acceptsGeometry else { return }
                verticalRestore.updateVerticalViewportPosition(model: model)
                Task { await self.annotations.refreshPosition() }
            },
            onTap: {
                handleVerticalTap()
            },
            onOpenImage: onOpenImage,
            onImageLongPress: { anchor, imageURL, chapterTitle in
                annotations.toggleImage(anchor, imageURL: imageURL, chapterTitle: chapterTitle)
            }
        )
        .contentShape(Rectangle())
    }
}
