import SwiftUI
import YamiboXCore

/// A separate observation boundary for paging layout and viewport selection.
struct NovelReaderPagedContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: NovelReaderViewModel
    let layout: NovelReaderLayout
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isPadDevice: Bool
    let pagedScrollAnimationRequest: ReaderPagedScrollAnimationRequest?
    let makeBindings: (ReaderPagedPagerIdentity) -> NovelReaderPagedViewportBindings

    /// Reduce Motion downgrades the 3D page-curl transition to the already
    /// available quick-fade style; direct-manipulation slide stays as is.
    private var effectivePagedSettings: NovelReaderAppearanceSettings {
        guard reduceMotion, model.settings.pagedTurnStyle == .pageCurl else { return model.settings }
        var adjusted = model.settings
        adjusted.pagedTurnStyle = .quickFade
        return adjusted
    }

    var body: some View {
        var displaySettings = effectivePagedSettings
        displaySettings.horizontalPadding = layout.novelTextBoxLayout(
            settings: model.settings, usesPadPresentation: isPadDevice
        ).contentInsets.leading
        let pagerIdentity = ReaderPagedPagerIdentity(
            visibleView: model.visibleView,
            surfaceCount: model.novelReaderSurfaces.count,
            spreadCount: model.presentationSpreads.count,
            usesTwoPageSpread: model.isTwoPageSpreadActive,
            layout: layout
        )
        let pagedTopInset = topInset + layout.chromeInsets.top
        // The turning sheet includes the home-indicator area; the text box
        // still ends at its original boundary above that area.
        let pagedBottomInset = layout.chromeInsets.bottom + bottomInset
        let bindings = makeBindings(pagerIdentity)
        let information = ReaderPageInformationPresentation(isPaged: true,
            isImmersive: model.settings.isImmersiveModeEnabled, isChromeVisible: bindings.isChromeVisible)
        let attachedInformation = ReaderAttachedInformationConfiguration(
            pages: model.attachedPageInformation(workTitle: model.title, information: information),
            presentation: information, selectedIndex: model.pagedViewportSelectionIndex,
            backgroundStyle: model.settings.backgroundStyle, topInset: topInset, bottomInset: bottomInset,
            titleSidePadding: model.navigation.canNavigateForward ? 128 : 76,
            titleLift: isPadDevice ? 12 : 0
        )
        return Group {
            if effectivePagedSettings.pagedTurnStyle == .pageCurl {
                NovelReaderPagedPageCurlViewport(
                    attachedInformation: attachedInformation,
                    structureID: model.presentationStructure?.id,
                    sequence: model.pageCurlSequence,
                    spreads: model.presentationSpreads,
                    surfaces: model.novelReaderSurfaces,
                    settings: displaySettings,
                    refererURL: model.forumURL,
                    offlineScope: model.inlineImageOfflineScope,
                    topInset: pagedTopInset,
                    bottomInset: pagedBottomInset,
                    selectionIndex: model.pagedViewportSelectionIndex,
                    usesTwoPageSpread: model.isTwoPageSpreadActive,
                    pagerIdentity: pagerIdentity,
                    scrollAnimationRequest: pagedScrollAnimationRequest,
                    displayReferenceProvider: bindings.displayReferenceProvider,
                    selectionController: bindings.selectionController,
                    likeHighlightController: bindings.likeHighlightController,
                    searchHighlightController: bindings.searchHighlightController,
                    likedImageAnchors: bindings.likedImageAnchors,
                    isChromeVisible: bindings.isChromeVisible,
                    canBoundaryPageTurn: bindings.canBoundaryPageTurn,
                    onSelectionChange: bindings.onSelectionChange,
                    onBoundaryPageTurn: bindings.onBoundaryPageTurn,
                    onBoundaryPageTurnRejected: bindings.onBoundaryPageTurnRejected,
                    onPageTapZone: bindings.onPageTapZone,
                    onScrollAnimationRequestConsumed: bindings.onScrollAnimationRequestConsumed,
                    onChromeVisibleImageTap: bindings.onChromeVisibleImageTap,
                    onImageTap: bindings.onImageTap,
                    onImageLongPress: bindings.onImageLongPress
                )
            } else {
                NovelReaderPagedCollectionViewport(
                    attachedInformation: attachedInformation,
                    structureID: model.presentationStructure?.id,
                    itemSource: model.isTwoPageSpreadActive
                        ? .spreads(model.presentationSpreads)
                        : .surfaces,
                    surfaces: model.novelReaderSurfaces,
                    settings: displaySettings,
                    refererURL: model.forumURL,
                    offlineScope: model.inlineImageOfflineScope,
                    topInset: pagedTopInset,
                    bottomInset: pagedBottomInset,
                    selectionIndex: model.pagedViewportSelectionIndex,
                    pagerIdentity: pagerIdentity,
                    scrollAnimationRequest: pagedScrollAnimationRequest,
                    displayReferenceProvider: bindings.displayReferenceProvider,
                    selectionController: bindings.selectionController,
                    likeHighlightController: bindings.likeHighlightController,
                    searchHighlightController: bindings.searchHighlightController,
                    likedImageAnchors: bindings.likedImageAnchors,
                    isChromeVisible: bindings.isChromeVisible,
                    canBoundaryPageTurn: bindings.canBoundaryPageTurn,
                    onSelectionChange: bindings.onSelectionChange,
                    onBoundaryPageTurn: bindings.onBoundaryPageTurn,
                    onBoundaryPageTurnRejected: bindings.onBoundaryPageTurnRejected,
                    onPageTapZone: bindings.onPageTapZone,
                    onScrollAnimationRequestConsumed: bindings.onScrollAnimationRequestConsumed,
                    onChromeVisibleImageTap: bindings.onChromeVisibleImageTap,
                    onImageTap: bindings.onImageTap,
                    onImageLongPress: bindings.onImageLongPress
                )
            }
        }
        .id(pagerIdentity)
        .scrollDisabled(bindings.isChromeVisible)
    }
}
