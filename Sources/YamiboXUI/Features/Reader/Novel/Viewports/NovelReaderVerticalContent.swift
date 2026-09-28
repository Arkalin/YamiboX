import SwiftUI
import YamiboXCore

/// Owns scroll-view wiring; the root receives only user interaction events.
struct NovelReaderVerticalContent: View {
    let model: NovelReaderViewModel
    let layout: NovelReaderLayout
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isPadDevice: Bool
    let isChromeVisible: Bool
    let verticalRestore: NovelReaderVerticalRestoreCoordinator
    let verticalScrollCoordinator: NovelReaderVerticalScrollCoordinator
    let annotations: NovelReaderAnnotationCoordinator
    let searchHighlightController: NovelReaderSearchHighlightController
    @Binding var verticalTapSuppressionUntil: CFTimeInterval
    let handleVerticalBoundaryPullRelease: (NovelReaderVerticalBoundaryDirection) async -> Void
    let updateVerticalBoundaryPullState: (NovelReaderVerticalBoundaryPullState) -> Void
    let handleVerticalTap: () -> Void
    let enterImmersiveMode: () -> Void
    let handleImageTap: (URL, String?) -> Void

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
            isChromeVisible: isChromeVisible,
            onVisibleSurfaceIdentitiesChange: { surfaceIdentities in
                model.updateNovelTextViewportVisibleSurfaceIdentities(surfaceIdentities)
            },
            onScrollRequestHandled: { request in
                verticalRestore.handleScrollRequestHandled(
                    request,
                    model: model,
                    scrollCoordinator: verticalScrollCoordinator
                )
            },
            onScrollViewReady: { scrollView in
                verticalScrollCoordinator.attach(scrollView: scrollView)
                verticalScrollCoordinator.onBoundaryPullRelease = { direction in
                    Task { @MainActor in
                        await handleVerticalBoundaryPullRelease(direction)
                    }
                }
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
                verticalRestore.updateVerticalViewportPosition(model: model)
                Task { await self.annotations.refreshPosition() }
            },
            onTap: {
                handleVerticalTap()
            },
            onChromeVisibleImageTap: {
                enterImmersiveMode()
            },
            onImageTap: { url, title in
                handleImageTap(url, title)
            },
            onImageLongPress: { anchor, imageURL, chapterTitle in
                annotations.toggleImage(anchor, imageURL: imageURL, chapterTitle: chapterTitle)
            }
        )
        .contentShape(Rectangle())
        .simultaneousGesture(verticalScrollSuppressionGesture)
    }

    private var verticalScrollSuppressionGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                verticalRestore.cancelVerticalRestoreForUserScroll()
                verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
            }
            .onEnded { _ in
                verticalTapSuppressionUntil = CACurrentMediaTime() + 0.5
            }
    }
}
