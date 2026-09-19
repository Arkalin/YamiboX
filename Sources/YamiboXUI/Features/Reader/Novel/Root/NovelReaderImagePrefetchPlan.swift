import Foundation
import YamiboXCore

enum NovelReaderImagePrefetchPlan {
    static func sources(
        presentation: NovelReaderPresentation,
        structure: NovelReaderPresentationStructure? = nil,
        usesTwoPageSpread: Bool,
        threadID: String,
        fallbackAuthorID: String?
    ) -> [YamiboImageSource] {
        guard presentation.committedSettings.loadsInlineImages,
              let selectedIndex = presentation.selectedSurfaceIndex,
              presentation.surfaces.indices.contains(selectedIndex) else { return [] }

        let offsets = [0, 1, 2, 3, -1, -2, -3]
        let surfaceIndices: [Int]
        if usesTwoPageSpread,
           let spreadIndex = structure?.spreadIndexBySurfaceIndex[selectedIndex] ?? presentation.spreads.firstIndex(where: {
               $0.leftSurfaceIndex == selectedIndex || $0.rightSurfaceIndex == selectedIndex
           }) {
            surfaceIndices = offsets.flatMap { offset -> [Int] in
                let index = spreadIndex + offset
                guard presentation.spreads.indices.contains(index) else { return [] }
                let spread = presentation.spreads[index]
                return [spread.leftSurfaceIndex, spread.rightSurfaceIndex].compactMap { $0 }
            }
        } else {
            surfaceIndices = offsets.map { selectedIndex + $0 }
        }

        var seen = Set<String>()
        return surfaceIndices.flatMap { index -> [YamiboImageSource] in
            guard presentation.surfaces.indices.contains(index) else { return [] }
            let surface = presentation.surfaces[index]
            let referer = YamiboRoute.threadByID(
                tid: threadID,
                page: surface.documentView,
                authorID: surface.resolvedAuthorID ?? presentation.readingState.authorID ?? fallbackAuthorID,
                reverse: false
            ).url
            return surface.externalBlocks.compactMap { block in
                let source = YamiboImageSource(
                    url: block.url,
                    refererPageURL: referer,
                    offlineScope: YamiboImageOfflineScope(tid: threadID)
                )
                return seen.insert(source.cacheKey).inserted ? source : nil
            }
        }
    }
}

/// A compact identity for resuming after memory pressure without retaining a presentation.
struct NovelReaderImagePrefetchPosition: Equatable {
    let generation: UInt64
    let surfaceCount: Int
    let surfaceIndex: Int?
    let intraSurfaceProgress: Double

    init(_ presentation: NovelReaderPresentation) {
        generation = presentation.generation
        surfaceCount = presentation.surfaces.count
        surfaceIndex = presentation.selectedSurfaceIndex
        intraSurfaceProgress = presentation.readingState.currentSurfaceIntraProgress
    }
}
