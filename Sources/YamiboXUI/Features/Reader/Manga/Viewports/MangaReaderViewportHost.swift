import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderPresentationContent: View {
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
                    onPageLongPress: onPageLongPress,
                    onTap: onTap
                )
            case let .failed(error):
                ReaderLoadStateView(
                    status: .failed(message: error.message),
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
                    onPageLongPress: onPageLongPress,
                    onTap: onTap
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .paged:
                GeometryReader { proxy in
                    let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                        settings: settings,
                        isPadDevice: UIDevice.current.userInterfaceIdiom == .pad,
                        availableSize: proxy.size
                    )
                    let plan = MangaPagedReadingPlan(
                        pages: loaded.pages,
                        currentPageIndex: loaded.currentPageIndex,
                        pageTurnDirection: settings.pageTurnDirection,
                        usesTwoPageSpread: usesTwoPageSpread
                    )
                    if effectiveSettings.pagedTurnStyle == .pageCurl {
                        MangaPagedPageCurlReaderViewport(
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
                            onPageLongPress: onPageLongPress,
                            onTap: onTap
                        )
                        .id(plan.usesTwoPageSpread)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        MangaPagedReaderViewport(
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
                            onPageLongPress: onPageLongPress,
                            onTap: onTap
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.top, pagedContentTopInset)
            }
        } else {
            ReaderLoadStateView(status: .loading, tint: .white)
        }
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
