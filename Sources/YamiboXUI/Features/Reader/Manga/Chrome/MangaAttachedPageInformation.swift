import YamiboXCore

#if os(iOS)
enum MangaAttachedPageInformation {
    static func pages(plan: MangaPagedReadingPlan, workTitle: String,
                      information: ReaderPageInformationPresentation,
                      chapterTitle: (MangaReaderPageProjection) -> String) -> [[ReaderAttachedPageInformation]] {
        plan.spreads.map { spread in
            let pages = plan.usesTwoPageSpread ? [spread.leftPage, spread.rightPage] : [spread.preferredPage]
            let anchor = spread.preferredPage
            let last = pages.compactMap { $0 }.filter { $0.tid == anchor.tid }.map(\.localIndex).max() ?? anchor.localIndex
            let titles = information.titles(work: plan.usesTwoPageSpread ? workTitle : nil,
                chapter: information.chapterText(title: chapterTitle(anchor), remainingPages: max(anchor.chapterPageCount - last - 1, 0)),
                isRightToLeft: plan.pageTurnDirection == .rightToLeft)
            return pages.enumerated().map { slot, page in
                ReaderAttachedPageInformation(pageID: page?.id, title: titles[slot],
                    pageNumber: page.map { $0.localIndex + 1 },
                    pageLine: page.map { L10n.string("manga.preview_page_label", String($0.localIndex + 1), max($0.chapterPageCount, 1)) } ?? "",
                    webLine: "")
            }
        }
    }
}
#endif
