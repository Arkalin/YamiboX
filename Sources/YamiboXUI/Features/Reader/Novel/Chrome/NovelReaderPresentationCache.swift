import Foundation
import YamiboXCore

/// UI-only, session-local derived data. Never stores a TextKit graph or images.
@MainActor
final class NovelReaderPresentationCache {
    private struct ProgressKey: Equatable {
        let structureID: UUID
        let mode: ReaderReadingMode
        let spread: Bool
        let direction: ReaderPageTurnDirection
        let locale: String
    }

    private struct AttachedKey: Equatable {
        let progress: ProgressKey
        let workTitle: String
        let maxView: Int
        let information: ReaderPageInformationPresentation
    }

    private struct SequenceKey: Equatable {
        let structureID: UUID
        let spread: Bool
        let direction: ReaderPageTurnDirection
    }

    private struct PositionKey: Equatable {
        let surfaceIndex: Int
        let view: Int
        let maxView: Int
        let chapterTitle: String?
    }

    private var progressKey: ProgressKey?
    private var positionKey: PositionKey?
    private var snapshot = NovelReaderChromeProgressSnapshot.empty
    private var attachedKey: AttachedKey?
    private var attachedPages: [[ReaderAttachedPageInformation]] = []
    private var sequenceKey: SequenceKey?
    private var sequence: NovelReaderPagedPageCurlSequence?
    private(set) var diagnostics = NovelReaderPresentationDiagnostics()

    func progress(
        presentation: NovelReaderPresentation, structure: NovelReaderPresentationStructure
    ) -> NovelReaderChromeProgressSnapshot {
        let key = key(presentation: presentation, structure: structure)
        let position = PositionKey(surfaceIndex: presentation.progressProjection.selectedSurfaceIndex,
                                   view: presentation.progressProjection.displayedView,
                                   maxView: presentation.readingState.maxView,
                                   chapterTitle: presentation.readingState.currentChapterTitle)
        if progressKey != key {
            attachedKey = nil
            attachedPages = []
            if progressKey?.structureID != key.structureID {
                sequenceKey = nil
                sequence = nil
            }
            progressKey = key
            diagnostics.progressIndexBuildCount += 1
            snapshot = NovelReaderPerformance.measure("chrome-index") {
                NovelReaderChromeProgressSnapshot(presentation: presentation, structure: structure)
            }
        } else if positionKey != position {
            NovelReaderPerformance.measure("chrome-position") {
                snapshot.updatePosition(presentation: presentation, structure: structure)
            }
        }
        positionKey = position
        return snapshot
    }

    func pages(
        presentation: NovelReaderPresentation, structure: NovelReaderPresentationStructure,
        workTitle: String, information: ReaderPageInformationPresentation
    ) -> [[ReaderAttachedPageInformation]] {
        let key = AttachedKey(progress: key(presentation: presentation, structure: structure),
                              workTitle: workTitle, maxView: presentation.readingState.maxView,
                              information: information)
        if attachedKey != key {
            attachedKey = key
            diagnostics.attachedInformationBuildCount += 1
            attachedPages = NovelReaderPerformance.measure("attached-information") {
                NovelAttachedPageInformation.pages(presentation: presentation, workTitle: workTitle,
                                                   information: information, structure: structure)
            }
        }
        return attachedPages
    }

    func pageCurlSequence(
        presentation: NovelReaderPresentation, structure: NovelReaderPresentationStructure
    ) -> NovelReaderPagedPageCurlSequence {
        let key = SequenceKey(structureID: structure.id,
                              spread: presentation.progressProjection.usesTwoPageSpread,
                              direction: presentation.progressProjection.pageTurnDirection)
        if sequenceKey == key, let sequence { return sequence }
        sequenceKey = key
        diagnostics.pageCurlSequenceBuildCount += 1
        let value = NovelReaderPerformance.measure("page-curl-sequence") {
            NovelReaderPagedPageCurlSequence(surfaces: structure.surfaces, spreads: structure.spreads,
                                            usesTwoPageSpread: key.spread, pageTurnDirection: key.direction)
        }
        sequence = value
        return value
    }

    func clear() {
        progressKey = nil
        positionKey = nil
        snapshot = .empty
        attachedKey = nil
        attachedPages = []
        sequenceKey = nil
        sequence = nil
    }

    private func key(
        presentation: NovelReaderPresentation, structure: NovelReaderPresentationStructure
    ) -> ProgressKey {
        ProgressKey(structureID: structure.id, mode: presentation.progressProjection.readingMode,
                    spread: presentation.progressProjection.usesTwoPageSpread,
                    direction: presentation.progressProjection.pageTurnDirection,
                    locale: Locale.current.identifier + "|" + L10n.bundle.preferredLocalizations.joined(separator: ","))
    }
}
