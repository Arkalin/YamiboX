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
    @State private var pagedCache = MangaPagedContentCache()

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
                    let plan = pagedCache.plan(
                        loaded: loaded,
                        direction: settings.pageTurnDirection,
                        usesTwoPageSpread: usesTwoPageSpread
                    )
                    if effectiveSettings.pagedTurnStyle == .pageCurl {
                        MangaPagedPageCurlReaderViewport(
                            attachedInformation: attachedInformation(plan: plan),
                            plan: plan,
                            sequence: pagedCache.pageCurlSequence(),
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
        result.pages = pagedCache.informationPages(isImmersive: settings.isImmersiveModeEnabled,
                                                  isChromeVisible: isChromeVisible)
        return result
    }
}

/// View-lifetime memoization, not observable state: selection and chrome reads
/// reuse immutable window data without scheduling a second layout pass.
@MainActor
private final class MangaPagedContentCache {
    private var basePlan: MangaPagedReadingPlan?
    private var cachedSequence: MangaPagedPageCurlSequence?
    private var chapters: [MangaChapter] = []
    private var workTitle = ""
    private var informationVariants: [Int: [[ReaderAttachedPageInformation]]] = [:]

    func plan(loaded: MangaReaderLoadedPresentation, direction: MangaPageTurnDirection,
              usesTwoPageSpread: Bool) -> MangaPagedReadingPlan {
        let structureChanged = basePlan?.pages != loaded.pages
            || basePlan?.pageTurnDirection != direction
            || basePlan?.usesTwoPageSpread != usesTwoPageSpread
        if structureChanged {
            cachedSequence = nil
            basePlan = MangaPagedReadingPlan(pages: loaded.pages, currentPageIndex: nil,
                pageTurnDirection: direction, usesTwoPageSpread: usesTwoPageSpread)
        }
        if structureChanged || chapters != loaded.directoryPanel.displayChapters || workTitle != loaded.directoryTitle {
            chapters = loaded.directoryPanel.displayChapters
            workTitle = loaded.directoryTitle
            var titles: [String: String] = [:]
            for chapter in chapters where titles[chapter.tid] == nil {
                titles[chapter.tid] = MangaChapterDisplayFormatter.readerHeaderTitle(
                    rawTitle: chapter.rawTitle, cleanBookName: workTitle)
            }
            for page in loaded.pages where titles[page.tid] == nil {
                titles[page.tid] = MangaChapterDisplayFormatter.readerHeaderTitle(
                    rawTitle: page.chapterTitle, cleanBookName: workTitle)
            }
            if let basePlan {
                for immersive in [false, true] {
                    for chrome in [false, true] {
                        informationVariants[key(immersive, chrome)] = MangaAttachedPageInformation.pages(
                            plan: basePlan, workTitle: workTitle,
                            information: ReaderPageInformationPresentation(isPaged: true,
                                isImmersive: immersive, isChromeVisible: chrome)) { titles[$0.tid] ?? $0.chapterTitle }
                    }
                }
            }
        }
        return basePlan!.selectingPage(at: loaded.currentPageIndex)
    }

    func informationPages(isImmersive: Bool, isChromeVisible: Bool) -> [[ReaderAttachedPageInformation]] {
        informationVariants[key(isImmersive, isChromeVisible)] ?? []
    }

    func pageCurlSequence() -> MangaPagedPageCurlSequence {
        if let cachedSequence { return cachedSequence }
        let sequence = MangaPagedPageCurlSequence(plan: basePlan!)
        cachedSequence = sequence
        return sequence
    }

    private func key(_ immersive: Bool, _ chrome: Bool) -> Int {
        (immersive ? 2 : 0) + (chrome ? 1 : 0)
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
