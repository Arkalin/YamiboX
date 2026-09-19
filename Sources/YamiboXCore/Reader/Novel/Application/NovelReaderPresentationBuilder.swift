import Foundation

/// The pure snapshot→presentation mapping, split out of
/// `NovelReadingWorkflow` so the workflow keeps only state ownership and
/// sequencing. Everything here is a static function of its inputs — no access
/// to workflow fields means a presentation can never observe half-committed
/// workflow state, and the mapping is testable without a live workflow.
enum NovelReaderPresentationBuilder {
    /// Builds only for a new content/layout generation. Candidates remain
    /// transaction-local until the corresponding runtime commits.
    static func makeStructure(
        snapshot: NovelReadingSnapshot,
        layoutResult: NovelTextLayoutResult?,
        generation: UInt64,
        fallbackLayout: NovelReaderLayout
    ) -> NovelReaderPresentationStructure {
        let readableSize = layoutResult?.viewportContext.identity.layout.readableFrame.size ?? fallbackLayout.readableFrame.size
        let indexSurfaces = (layoutResult?.viewportIndex.surfaces ?? []).sorted { lhs, rhs in
            lhs.surfaceOrdinal < rhs.surfaceOrdinal
        }
        let surfaces = indexSurfaces.enumerated().map { index, surface in
            let presentationHeight = layoutResult?.layoutMetrics.surfaceHeight(for: surface.surfaceOrdinal) ?? readableSize.height
            let nextSurface = indexSurfaces.indices.contains(index + 1) ? indexSurfaces[index + 1] : nil
            let spacingAfter: CGFloat = {
                guard let nextSurface else { return 0 }
                return surface.externalBlocks.isEmpty && nextSurface.externalBlocks.isEmpty ? 0 : 14
            }()
            return NovelReaderSurface(
                identity: NovelReaderSurfaceIdentity(
                    generation: generation,
                    ordinal: surface.surfaceOrdinal
                ),
                presentationIndex: index,
                kind: surface.externalBlocks.isEmpty ? .text : .externalBlock,
                documentView: surface.documentView,
                chapterTitle: surface.chapterTitle,
                presentationSize: CGSize(width: readableSize.width, height: presentationHeight),
                presentationSpacingAfter: spacingAfter,
                externalBlocks: surface.externalBlocks.map { externalBlock in
                    NovelReaderExternalBlock(
                        url: externalBlock.url,
                        frame: externalBlock.frozenFrame.map {
                            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                        },
                        chapterIdentity: externalBlock.chapterIdentity,
                        imageSegmentIdentity: externalBlock.imageSegmentIdentity,
                        chapterOrdinal: externalBlock.chapterOrdinal
                    )
                },
                chapterCommentTarget: surface.chapterCommentTarget,
                resolvedAuthorID: snapshot.currentAuthorID
            )
        }
        let surfaceIdentityByOrdinal = Dictionary(
            uniqueKeysWithValues: surfaces.map { ($0.identity.ordinal, $0.identity) }
        )
        let surfaceIndexByOrdinal = Dictionary(
            uniqueKeysWithValues: surfaces.map { ($0.identity.ordinal, $0.presentationIndex) }
        )
        let spreads = NovelReadingSpread.makeSpreads(from: indexSurfaces).compactMap { spread -> NovelReaderPresentationSpread? in
            guard let leftIdentity = surfaceIdentityByOrdinal[spread.leftSurfaceIndex] else {
                return nil
            }
            return NovelReaderPresentationSpread(
                index: spread.index,
                leftSurfaceIndex: surfaceIndexByOrdinal[spread.leftSurfaceIndex] ?? spread.index,
                leftSurfaceIdentity: leftIdentity,
                rightSurfaceIndex: spread.rightSurfaceIndex.flatMap { surfaceIndexByOrdinal[$0] },
                rightSurfaceIdentity: spread.rightSurfaceIndex.flatMap { surfaceIdentityByOrdinal[$0] },
                chapterTitle: spread.chapterTitle
            )
        }
        return NovelReaderPresentationStructure(
            generation: generation,
            resolvedAuthorID: snapshot.currentAuthorID,
            surfaces: surfaces,
            spreads: spreads,
            chapters: layoutResult?.viewportIndex.novelReaderChapters ?? []
        )
    }

    static func makePresentation(
        snapshot: NovelReadingSnapshot,
        structure: NovelReaderPresentationStructure,
        revision: UInt64,
        settings: NovelReaderAppearanceSettings,
        usesTwoPageSpread: Bool,
        pageLoadSource: NovelReaderProjectionLoadSource
    ) -> NovelReaderPresentation {
        let selectedSurfaceIndex = structure.surfaceIndexByOrdinal[snapshot.selectedSurfaceOrdinal]
        let readingState = NovelReaderReadingState(
            currentView: snapshot.currentView,
            maxView: snapshot.maxView,
            currentChapterTitle: snapshot.currentChapterTitle,
            authorID: snapshot.currentAuthorID,
            currentSurfaceIntraProgress: snapshot.currentSurfaceIntraProgress
        )
        let progressProjection = NovelReaderProgressProjection(
            readingMode: settings.readingMode,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: settings.pageTurnDirection,
            structure: structure,
            selectedSurfaceIndex: selectedSurfaceIndex ?? 0,
            readingState: readingState
        )
        return NovelReaderPresentation(
            generation: structure.generation,
            revision: revision,
            surfaces: structure.surfaces,
            selectedSurfaceIdentity: selectedSurfaceIndex.map { structure.surfaces[$0].identity },
            spreads: structure.spreads,
            chapters: structure.chapters,
            committedSettings: settings,
            readingState: readingState,
            pageLoadSource: pageLoadSource,
            retainedChapterCount: snapshot.retainedChapterCount,
            filteredChapterCandidateCount: snapshot.filteredChapterCandidateCount,
            selectedSurfaceIndex: selectedSurfaceIndex,
            progressProjection: progressProjection,
            usesTwoPageSpread: usesTwoPageSpread
        )
    }

    /// Moved verbatim from `NovelReadingWorkflow.usesPagedSpread`: the
    /// two-page spread is a paged-mode, pad-only, landscape-only presentation
    /// decision, and it must be computed from the same settings/layout values
    /// a presentation or session mutation is being built with (not always the
    /// workflow's committed fields), which is why it takes all three inputs
    /// explicitly.
    static func usesPagedSpread(
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) -> Bool {
        layout.usesTwoPageSpread(settings: settings, usesPadPresentation: usesPadPresentation)
    }
}
