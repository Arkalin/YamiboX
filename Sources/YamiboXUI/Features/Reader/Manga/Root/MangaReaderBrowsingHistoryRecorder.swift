import Foundation
import YamiboXCore

@MainActor
final class MangaReaderBrowsingHistoryRecorder {
    struct Reading {
        var makeBrowsingHistoryWorkflow: @Sendable () -> BrowsingHistoryWorkflow
        var currentDirectory: @MainActor () -> MangaDirectory?
    }

    private let context: MangaLaunchContext
    private let reading: Reading
    private var hasRecorded = false
    private var lastChapterID: String?

    init(context: MangaLaunchContext, reading: Reading) {
        self.context = context
        self.reading = reading
    }

    func syncRecordIfNeeded(presentation: MangaReaderPresentation) {
        guard !context.isPreview, case let .loaded(loaded) = presentation.state else { return }
        let history = reading.makeBrowsingHistoryWorkflow()
        let page = loaded.currentPage
        let tid = page?.tid ?? context.chapterTID
        // Page positions use the progress adapter; directory metadata uses
        // the shared workflow's change observer.
        guard !hasRecorded || lastChapterID != tid else { return }
        let title = loaded.directoryPanel.displayChapters.first(where: { $0.tid == tid })?.rawTitle
            ?? page?.chapterTitle ?? context.displayTitle
        let visit = BrowsingHistoryVisit(
            threadID: tid, title: title,
            forumID: context.forumID, reader: .manga, directory: reading.currentDirectory()
        )
        let isFirstVisit = !hasRecorded
        hasRecorded = true
        lastChapterID = tid
        Task {
            do {
                if isFirstVisit { try await history.recordVisit(visit) }
                else { try await history.updateActivity(visit) }
            } catch {
                YamiboLog.reader.warning("Failed to record manga browsing history: \(error)")
            }
        }
    }

    func reset() {
        hasRecorded = false
        lastChapterID = nil
    }
}
