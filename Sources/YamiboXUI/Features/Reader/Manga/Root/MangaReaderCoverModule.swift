import Foundation
import YamiboXCore

/// Owns the manga reader's cover management: the mode-gated cover key,
/// manual cover set/restore from a long-pressed page, and the one-shot
/// automatic `.thread(tid:)` cover resolution that mode-off sessions run
/// after a successful prepare. Stateless toward the UI — outcomes surface
/// through the cover store and the caller's own feedback toasts — so the
/// module carries no published state.
@MainActor
final class MangaReaderCoverModule {
    /// Reading context supplied by the owning view model.
    struct Reading {
        var isSmartModeEnabled: Bool
        var chapterTID: String
        var displayTitle: String
        var currentDirectoryCleanBookName: @MainActor () -> String?
        var makeContentCoverStore: @Sendable () -> ContentCoverStore?
        var makeThreadCoverPageRepository: @Sendable () async -> (any ThreadCoverPageResolving)?
        var imageSource: @MainActor (MangaReaderPageProjection) -> YamiboImageSource
        var isReaderLoaded: @MainActor () -> Bool
    }

    private let reading: Reading
    private var autoThreadCoverResolutionTask: Task<Void, Never>?

    init(reading: Reading) {
        self.reading = reading
    }

    deinit {
        // The resolution task rides the module's lifetime (it was moved
        // here from the view model together with the logic it serves).
        autoThreadCoverResolutionTask?.cancel()
    }

    private var mangaCoverKey: ContentCoverKey? {
        // Smart Comic Mode off (design decisions #2's 总原则 and #16): this
        // chapter is read exactly like a normal thread, so the cover entry
        // writes the same `.thread(tid:)` key `ImageBrowserCoverActions`
        // uses for a normal thread's "设为封面" action, keyed by this
        // chapter's own thread id. This branches on `context
        // .isSmartModeEnabled` directly rather than, say, whether
        // `workflow?.currentDirectoryCleanBookName()` happens to be
        // non-nil — the mode-off synthesized single-chapter pseudo-
        // directory (`MangaReaderWorkflow.standaloneDirectory`) has a
        // non-nil cleanBookName too, which is exactly the proxy-signal trap
        // that caused the Like-feature and AppContinuityWorkflow bugs in
        // earlier phases.
        guard reading.isSmartModeEnabled else {
            return .thread(tid: reading.chapterTID)
        }
        guard let cleanBookName = reading.currentDirectoryCleanBookName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cleanBookName.isEmpty else {
            return nil
        }
        return .smartManga(cleanBookName: cleanBookName)
    }

    var canSetMangaCover: Bool {
        mangaCoverKey != nil && reading.makeContentCoverStore() != nil
    }

    func hasManualMangaCover() async -> Bool {
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        return await store.cover(for: key)?.manualCoverURL != nil
    }

    func setMangaCover(page: MangaReaderPageProjection) async -> Bool {
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        do {
            try await store.setManualCover(reading.imageSource(page).url, for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to set manual manga cover: \(error.localizedDescription)")
            return false
        }
    }

    func restoreAutomaticMangaCover() async -> Bool {
        guard let key = mangaCoverKey, let store = reading.makeContentCoverStore() else { return false }
        do {
            try await store.clearManualCover(for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to clear manual manga cover: \(error.localizedDescription)")
            return false
        }
    }

    /// Smart Comic Mode off (design decisions #2's 总原则 and #16): this
    /// chapter is read exactly like a normal thread, so it gets the same
    /// automatic `.thread(tid:)` cover resolution `ForumThreadReaderViewModel`
    /// already performs for normal threads — reusing the same
    /// `ThreadCoverResolver` mechanism. `ForumThreadReaderViewModel` hangs its
    /// call off adding the thread to favorites (it has no other lifecycle
    /// hook); the manga reader has no favorite-toggle action of its own, so
    /// opening the reader (a successful `prepare()`) is its closest
    /// equivalent trigger. Like that reference call site, this doesn't check
    /// for an existing cover first — it unconditionally overwrites the
    /// automatic cover, same as `setAutomaticCover` always does.
    ///
    /// Mode-on chapters never do this: their cover comes from the existing
    /// smartManga backfill mechanism elsewhere (design decision #13, a later
    /// phase), not from the reader itself.
    func startAutoThreadCoverResolutionIfNeeded() {
        guard !reading.isSmartModeEnabled,
              reading.isReaderLoaded(),
              autoThreadCoverResolutionTask == nil else {
            return
        }
        autoThreadCoverResolutionTask = Task { @MainActor [weak self] in
            await self?.performAutoThreadCoverResolution()
        }
    }

    /// Reader-session teardown (retryInitialLoad): abandon an in-flight
    /// resolution so the fresh session can schedule its own.
    func cancelAutoThreadCoverResolution() {
        autoThreadCoverResolutionTask?.cancel()
        autoThreadCoverResolutionTask = nil
    }

    private func performAutoThreadCoverResolution() async {
        defer { autoThreadCoverResolutionTask = nil }
        guard let coverStore = reading.makeContentCoverStore(),
              let repository = await reading.makeThreadCoverPageRepository() else {
            return
        }
        let tid = reading.chapterTID
        guard let coverCandidate = await ThreadCoverResolver().resolve(
            thread: ThreadIdentity(tid: tid),
            title: reading.displayTitle,
            repository: repository
        ) else {
            return
        }
        do {
            _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: tid))
        } catch {
            YamiboLog.library.error("Failed to set automatic cover for manga chapter thread \(tid) while Smart Comic Mode is off: \(error.localizedDescription)")
        }
    }
}
