import YamiboXCore

#if os(iOS)
enum NovelAttachedPageInformation {
    static func pages(presentation: NovelReaderPresentation, workTitle: String,
                      information: ReaderPageInformationPresentation) -> [[ReaderAttachedPageInformation]] {
        let surfaces = presentation.surfaces
        let spread = presentation.progressProjection.usesTwoPageSpread
        let rtl = presentation.committedSettings.pageTurnDirection == .rightToLeft
        let groups: [[Int?]] = spread
            ? presentation.spreads.map { [$0.leftSurfaceIndex, $0.rightSurfaceIndex] }
            : surfaces.indices.map { [$0] }
        let totals = Dictionary(grouping: surfaces, by: \.documentView).mapValues(\.count)
        var counts: [Int: Int] = [:]
        let numbers = surfaces.map { surface in
            counts[surface.documentView, default: 0] += 1
            return counts[surface.documentView, default: 1]
        }
        return groups.map { indexes in
            let visible = indexes.compactMap { $0 }.filter { surfaces.indices.contains($0) }
            guard let first = visible.first else { return [] }
            let anchor = spread && !rtl ? (visible.last ?? first) : first
            let chapter = presentation.chapters.last { $0.startIndex <= anchor }
            let chapterTitle = surfaces[anchor].chapterTitle ?? chapter?.title ?? ""
            let end = presentation.chapters.first { $0.startIndex > anchor }?.startIndex ?? surfaces.count
            let remaining = max(end - (visible.filter { $0 < end }.max() ?? anchor) - 1, 0)
            let titles = information.titles(work: spread ? workTitle : nil,
                chapter: information.chapterText(title: chapterTitle, remainingPages: remaining), isRightToLeft: rtl)
            return indexes.enumerated().map { slot, index in
                guard let index, surfaces.indices.contains(index) else {
                    return ReaderAttachedPageInformation(pageID: nil, title: titles[slot], pageNumber: nil, pageLine: "", webLine: "")
                }
                let surface = surfaces[index]
                let summary = ReaderChromeProgressSummary(chapterTitle: nil, progressText: L10n.string(
                    "reader.progress", String(numbers[index]), totals[surface.documentView] ?? 1,
                    surface.documentView, max(presentation.readingState.maxView, 1)))
                return ReaderAttachedPageInformation(pageID: String(describing: surface.identity), title: titles[slot],
                    pageNumber: numbers[index], pageLine: summary.pageProgressLine, webLine: summary.webProgressLine)
            }
        }
    }
}
#endif
