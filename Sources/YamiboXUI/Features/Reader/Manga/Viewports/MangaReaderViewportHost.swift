import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderPresentationContent: View {
    var informationLayout = ReaderAttachedInformationConfiguration()
    let presentation: MangaReaderPresentation
    let imageLoader: MangaReaderPageImageLoader?
    let isChromeVisible: Bool
    let likedPageIDs: Set<String>
    let pagedContentTopInset: CGFloat
    let controlScrollStep: ReaderControlScrollStepRequest?
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
    let onRetryInitialLoad: () -> Void
    let onCurrentPageChange: (Int) -> Void
    let canBoundaryPageTurn: (Int, Bool) -> Bool
    let onBoundaryPageTurn: (Int, Bool) -> Void
    let onControlScrollEdgeReached: (ReaderControlScrollDirection) -> Void
    var onVerticalBoundaryPull: (ReaderPageBoundary) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch presentation.state {
            case .loading:
                ReaderLoadStateView(status: .loading, tint: .white)
            case let .loaded(loaded):
                MangaReaderLoadedContent(
                    informationLayout: informationLayout,
                    loaded: loaded,
                    settings: presentation.settings,
                    imageLoader: imageLoader,
                    isChromeVisible: isChromeVisible,
                    likedPageIDs: likedPageIDs,
                    pagedContentTopInset: pagedContentTopInset,
                    controlScrollStep: controlScrollStep,
                    controlPageTurnBridge: controlPageTurnBridge,
                    onCurrentPageChange: onCurrentPageChange,
                    canBoundaryPageTurn: canBoundaryPageTurn,
                    onBoundaryPageTurn: onBoundaryPageTurn,
                    onControlScrollEdgeReached: onControlScrollEdgeReached,
                    onVerticalBoundaryPull: onVerticalBoundaryPull,
                    onPageLongPress: onPageLongPress,
                    onTap: onTap
                )
            case let .failed(error):
                ReaderLoadStateView(
                    status: .failed(message: error.message, details: error.details),
                    retryAction: onRetryInitialLoad,
                    tint: .white
                )
            }

            brightnessOverlay(brightness: presentation.settings.brightness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func brightnessOverlay(brightness: Double) -> some View {
        let delta = brightness - 1
        if delta < 0 {
            Color.black.opacity(min(0.7, abs(delta)))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else if delta > 0 {
            Color.white.opacity(min(0.18, delta * 0.18))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

private struct MangaReaderLoadedContent: View {
    let informationLayout: ReaderAttachedInformationConfiguration
    let loaded: MangaReaderLoadedPresentation
    let settings: MangaReaderSettings
    let imageLoader: MangaReaderPageImageLoader?
    let isChromeVisible: Bool
    let likedPageIDs: Set<String>
    let pagedContentTopInset: CGFloat
    let controlScrollStep: ReaderControlScrollStepRequest?
    let controlPageTurnBridge: MangaPagedControlPageTurnBridge
    let onCurrentPageChange: (Int) -> Void
    let canBoundaryPageTurn: (Int, Bool) -> Bool
    let onBoundaryPageTurn: (Int, Bool) -> Void
    let onControlScrollEdgeReached: (ReaderControlScrollDirection) -> Void
    var onVerticalBoundaryPull: (ReaderPageBoundary) -> Void = { _ in }
    let onPageLongPress: (MangaReaderPageProjection) -> Void
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion downgrades the 3D page-curl transition to the already
    /// available quick-fade style; direct-manipulation slide stays as is.
    private var effectiveSettings: MangaReaderSettings {
        guard reduceMotion, settings.pagedTurnStyle == .pageCurl else { return settings }
        var adjusted = settings
        adjusted.pagedTurnStyle = .quickFade
        return adjusted
    }

    var body: some View {
        if loaded.pages.isEmpty {
            MangaReaderEmptyContent()
        } else if let imageLoader {
            switch settings.readingMode {
            case .vertical:
                MangaVerticalCollectionViewport(
                    pages: loaded.pages,
                    currentPageIndex: loaded.currentPageIndex,
                    viewportPlacement: loaded.viewportPlacement,
                    controlScrollStep: controlScrollStep,
                    imageLoader: imageLoader,
                    isChromeVisible: isChromeVisible,
                    zoomEnabled: settings.zoomEnabled,
                    likedPageIDs: likedPageIDs,
                    onCurrentPageChange: onCurrentPageChange,
                    onControlScrollEdgeReached: onControlScrollEdgeReached,
                    onVerticalBoundaryPull: onVerticalBoundaryPull,
                    onPageLongPress: onPageLongPress,
                    onTap: onTap
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .paged:
                GeometryReader { proxy in
                    let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                        settings: settings,
                        isPadDevice: UIDevice.current.userInterfaceIdiom == .pad,
                        availableSize: CGSize(width: proxy.size.width, height: max(proxy.size.height - pagedContentTopInset, 0))
                    )
                    let plan = MangaPagedReadingPlan(
                        pages: loaded.pages,
                        currentPageIndex: loaded.currentPageIndex,
                        pageTurnDirection: settings.pageTurnDirection,
                        usesTwoPageSpread: usesTwoPageSpread
                    )
                    if effectiveSettings.pagedTurnStyle == .pageCurl {
                        MangaPagedPageCurlReaderViewport(
                            attachedInformation: attachedInformation(plan: plan),
                            plan: plan,
                            viewportPlacement: loaded.viewportPlacement,
                            settings: effectiveSettings,
                            imageLoader: imageLoader,
                            isChromeVisible: isChromeVisible,
                            zoomEnabled: settings.zoomEnabled,
                            likedPageIDs: likedPageIDs,
                            controlPageTurnBridge: controlPageTurnBridge,
                            onCurrentPageChange: onCurrentPageChange,
                            canBoundaryPageTurn: { delta in
                                canBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onBoundaryPageTurn: { delta in
                                onBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onBoundaryPageTurnRejected: { delta in
                                onBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onPageLongPress: onPageLongPress,
                            onTap: onTap
                        )
                        .id(plan.usesTwoPageSpread)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        MangaPagedReaderViewport(
                            attachedInformation: attachedInformation(plan: plan),
                            plan: plan,
                            viewportPlacement: loaded.viewportPlacement,
                            settings: effectiveSettings,
                            imageLoader: imageLoader,
                            isChromeVisible: isChromeVisible,
                            zoomEnabled: settings.zoomEnabled,
                            likedPageIDs: likedPageIDs,
                            controlPageTurnBridge: controlPageTurnBridge,
                            onCurrentPageChange: onCurrentPageChange,
                            canBoundaryPageTurn: { delta in
                                canBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onBoundaryPageTurn: { delta in
                                onBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onBoundaryPageTurnRejected: { delta in
                                onBoundaryPageTurn(delta, usesTwoPageSpread)
                            },
                            onPageLongPress: onPageLongPress,
                            onTap: onTap
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            ReaderLoadStateView(status: .loading, tint: .white)
        }
    }

    private func attachedInformation(plan: MangaPagedReadingPlan) -> ReaderAttachedInformationConfiguration {
        var result = informationLayout
        result.contentTopInset = pagedContentTopInset
        result.presentation = ReaderPageInformationPresentation(isPaged: true,
            isImmersive: settings.isImmersiveModeEnabled, isChromeVisible: isChromeVisible)
        result.selectedIndex = plan.currentSpreadIndex ?? 0
        result.pages = MangaAttachedPageInformation.pages(plan: plan, workTitle: loaded.directoryTitle,
            information: result.presentation) { page in
                let rawTitle = loaded.directoryPanel.displayChapters.first { $0.tid == page.tid }?.rawTitle ?? page.chapterTitle
                return MangaChapterDisplayFormatter.readerHeaderTitle(rawTitle: rawTitle, cleanBookName: loaded.directoryTitle)
            }
        return result
    }
}

private struct MangaReaderEmptyContent: View {
    var body: some View {
        VStack(spacing: 12) {
            Label(L10n.string("manga.no_chapters"), systemImage: "photo.on.rectangle")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
#endif
