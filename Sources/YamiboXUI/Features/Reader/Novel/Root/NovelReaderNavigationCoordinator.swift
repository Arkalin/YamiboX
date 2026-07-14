import SwiftUI
import YamiboXCore

/// Position key used to expire nonlinear navigation history after enough
/// linear reading on the same page.
struct NovelReaderLinearReadingPageKey: Equatable, Sendable {
    var view: Int
    var surfaceIndex: Int
}

/// Aggregated non-current-view chapter directory browsing state.
struct NovelReaderChapterDirectoryState: Equatable {
    var view: Int? = nil
    var chapters: [NovelReaderChapter] = []
    var pageCount = 0
    var isLoading = false
    var error: String? = nil
}

/// Owns the novel reader's wayfinding: browsing the chapter catalog of other
/// web views, and the nonlinear navigation history (back/forward anchors
/// with linear-reading expiration). The view model supplies the reading
/// context and load effects; catalog and chrome views bind this coordinator
/// directly.
@MainActor
final class NovelReaderNavigationCoordinator: ObservableObject {
    /// Reading context and load effects supplied by the owning view model.
    struct Reading {
        var maxView: @MainActor () -> Int
        var visibleView: @MainActor () -> Int
        var chapters: @MainActor () -> [NovelReaderChapter]
        var surfaceCount: @MainActor () -> Int
        var currentChapterIndex: @MainActor () -> Int?
        var stableResumePoint: @MainActor () -> NovelResumePoint?
        var currentPageKey: @MainActor () -> NovelReaderLinearReadingPageKey?
        var previewChapterCatalog: @MainActor (Int) async throws -> [NovelChapterDirectoryEntry]
        var jumpToChapter: @MainActor (NovelReaderChapter) -> Void
        /// Opens a chapter anchor in another web view; returns nil when the
        /// reading workflow is unavailable so the caller can fall back to a
        /// plain view load.
        var openChapterAnchor: @MainActor (NovelChapterAnchor) async -> Bool?
        var loadWebView: @MainActor (Int) async -> Bool
        var restoreResumePoint: @MainActor (NovelResumePoint) async -> Bool
        var scheduleProgressSync: @MainActor () -> Void
    }

    @Published private(set) var chapterDirectory = NovelReaderChapterDirectoryState()
    @Published private var navigationHistory = ReaderNavigationHistory<NovelResumePoint>()

    private let reading: Reading
    private var chapterDirectoryAnchors: [Int: NovelChapterAnchor] = [:]
    private var linearReadingHistoryExpiration = ReaderNavigationLinearReadingExpiration<NovelReaderLinearReadingPageKey>()
    private var navigationRequestSequence: UInt64 = 0

    init(reading: Reading) {
        self.reading = reading
    }

    // MARK: - Navigation history

    var canNavigateBack: Bool {
        reading.stableResumePoint() != nil && navigationHistory.canGoBack
    }

    var canNavigateForward: Bool {
        reading.stableResumePoint() != nil && navigationHistory.canGoForward
    }

    func navigateBack() async {
        await restoreNavigationAnchor(direction: .back)
    }

    func navigateForward() async {
        await restoreNavigationAnchor(direction: .forward)
    }

    func beginNavigationRequest() -> UInt64 {
        navigationRequestSequence &+= 1
        return navigationRequestSequence
    }

    func isCurrentNavigationRequest(_ sequence: UInt64) -> Bool {
        navigationRequestSequence == sequence
    }

    func recordSuccessfulNonlinearNavigation(
        from sourceResumePoint: NovelResumePoint?,
        to targetResumePoint: NovelResumePoint?
    ) {
        guard let sourceResumePoint, let targetResumePoint, sourceResumePoint != targetResumePoint else { return }
        navigationHistory.recordNonlinearJump(from: sourceResumePoint, to: targetResumePoint)
        armLinearReadingHistoryExpirationIfNeeded()
    }

    func recordLinearReading(direction: ReaderNavigationLinearReadingDirection) {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward else {
            linearReadingHistoryExpiration.reset()
            return
        }
        guard let pageKey = reading.currentPageKey() else { return }
        if linearReadingHistoryExpiration.recordLinearReading(at: pageKey, direction: direction) {
            navigationHistory.clear()
        }
    }

    func resetHistory() {
        navigationHistory = ReaderNavigationHistory()
        linearReadingHistoryExpiration.reset()
    }

    private enum NavigationRestoreDirection {
        case back
        case forward
    }

    private func restoreNavigationAnchor(direction: NavigationRestoreDirection) async {
        guard let sourceResumePoint = reading.stableResumePoint() else { return }
        let navigationSequence = beginNavigationRequest()

        while let targetResumePoint = navigationTarget(for: direction) {
            let didRestore = await reading.restoreResumePoint(targetResumePoint)
            if didRestore {
                guard isCurrentNavigationRequest(navigationSequence) else { return }
                commitNavigationRestore(direction: direction, sourceResumePoint: sourceResumePoint)
                reading.scheduleProgressSync()
                return
            }
            guard isCurrentNavigationRequest(navigationSequence) else { return }
            discardNavigationTarget(for: direction)
        }
    }

    private func navigationTarget(for direction: NavigationRestoreDirection) -> NovelResumePoint? {
        switch direction {
        case .back:
            navigationHistory.peekBack()
        case .forward:
            navigationHistory.peekForward()
        }
    }

    private func commitNavigationRestore(
        direction: NavigationRestoreDirection,
        sourceResumePoint: NovelResumePoint
    ) {
        switch direction {
        case .back:
            navigationHistory.commitBack(from: sourceResumePoint)
        case .forward:
            navigationHistory.commitForward(from: sourceResumePoint)
        }
        armLinearReadingHistoryExpirationIfNeeded()
    }

    private func discardNavigationTarget(for direction: NavigationRestoreDirection) {
        switch direction {
        case .back:
            navigationHistory.discardBackCandidate()
        case .forward:
            navigationHistory.discardForwardCandidate()
        }
        resetLinearReadingHistoryExpirationIfHistoryIsEmpty()
    }

    private func armLinearReadingHistoryExpirationIfNeeded() {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward,
              let pageKey = reading.currentPageKey() else {
            linearReadingHistoryExpiration.reset()
            return
        }
        linearReadingHistoryExpiration.arm(at: pageKey)
    }

    private func resetLinearReadingHistoryExpirationIfHistoryIsEmpty() {
        guard !navigationHistory.canGoBack, !navigationHistory.canGoForward else { return }
        linearReadingHistoryExpiration.reset()
    }

    // MARK: - Chapter directory browsing

    var visibleChapterDirectoryView: Int {
        chapterDirectory.view ?? reading.visibleView()
    }

    var visibleChapterDirectoryChapters: [NovelReaderChapter] {
        chapterDirectory.view == nil ? reading.chapters() : chapterDirectory.chapters
    }

    var visibleChapterDirectoryPageCount: Int {
        chapterDirectory.view == nil ? reading.surfaceCount() : max(chapterDirectory.pageCount, 1)
    }

    var previousChapterDirectoryWebView: Int? {
        let target = visibleChapterDirectoryView - 1
        return target >= 1 ? target : nil
    }

    var nextChapterDirectoryWebView: Int? {
        let target = visibleChapterDirectoryView + 1
        return target <= reading.maxView() ? target : nil
    }

    var chapterDirectoryWebTitle: String {
        L10n.string(
            "reader.web_view_chapters",
            L10n.string("reader.web_view_progress", visibleChapterDirectoryView, max(reading.maxView(), 1))
        )
    }

    var currentChapterDirectoryIndex: Int? {
        guard chapterDirectory.view == nil || visibleChapterDirectoryView == reading.visibleView() else { return nil }
        return reading.currentChapterIndex()
    }

    func isCurrentChapterDirectoryChapter(_ chapter: NovelReaderChapter) -> Bool {
        guard visibleChapterDirectoryView == reading.visibleView(),
              let currentChapterDirectoryIndex else { return false }
        return chapter.ordinal == currentChapterDirectoryIndex
    }

    func resetChapterDirectoryBrowsing() {
        chapterDirectory = NovelReaderChapterDirectoryState()
        chapterDirectoryAnchors = [:]
    }

    func previewChapterDirectoryWebView(_ view: Int) async {
        let clampedView = max(1, min(reading.maxView(), view))
        if clampedView == reading.visibleView() {
            resetChapterDirectoryBrowsing()
            return
        }

        chapterDirectory = NovelReaderChapterDirectoryState(view: clampedView, isLoading: true)
        do {
            let entries = try await reading.previewChapterCatalog(clampedView)
            chapterDirectory.chapters = entries.map(\.chapter)
            chapterDirectoryAnchors = Dictionary(
                uniqueKeysWithValues: entries.compactMap { entry in
                    entry.anchor.map { (entry.chapter.ordinal, $0) }
                }
            )
            chapterDirectory.isLoading = false
        } catch {
            chapterDirectory.error = error.localizedDescription
            chapterDirectory.isLoading = false
        }
    }

    func jumpToChapterDirectoryChapter(_ chapter: NovelReaderChapter) async {
        let navigationSequence = beginNavigationRequest()
        let sourceResumePoint = reading.stableResumePoint()
        let targetView = visibleChapterDirectoryView
        let anchor = chapterDirectoryAnchors[chapter.ordinal]
        resetChapterDirectoryBrowsing()
        if targetView == reading.visibleView() {
            reading.jumpToChapter(chapter)
            return
        }
        guard let anchor, let didOpen = await reading.openChapterAnchor(anchor) else {
            let didLoad = await reading.loadWebView(targetView)
            if didLoad, isCurrentNavigationRequest(navigationSequence) {
                recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: reading.stableResumePoint())
            }
            return
        }
        guard didOpen else { return }
        reading.scheduleProgressSync()
        if isCurrentNavigationRequest(navigationSequence) {
            recordSuccessfulNonlinearNavigation(from: sourceResumePoint, to: reading.stableResumePoint())
        }
    }
}
