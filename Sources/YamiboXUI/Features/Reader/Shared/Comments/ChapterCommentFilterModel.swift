import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class ChapterCommentFilterModel {
    private(set) var state: ReaderChapterCommentsState = .idle
    private(set) var hasHiddenComments = false
    @ObservationIgnored private var rawState: ReaderChapterCommentsState = .idle
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let engine = ChapterCommentFilterEngine()
    private let settingsStore: SettingsStore
    private let sessionStore: SessionStore
    private let profileStore: YamiboProfileStore

    init(settingsStore: SettingsStore, sessionStore: SessionStore, profileStore: YamiboProfileStore) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.profileStore = profileStore
    }

    func update(_ rawState: ReaderChapterCommentsState) {
        self.rawState = rawState
        refresh()
    }

    func refresh() {
        cancel()
        let request = generation
        guard case let .loaded(target, page) = rawState else {
            state = rawState
            hasHiddenComments = false
            return
        }
        // Do not expose another chapter's list while the new projection loads.
        if case let .loaded(previousTarget, _) = state, previousTarget == target {} else {
            state = .loading(target)
        }
        task = Task { [weak self, settingsStore, sessionStore, profileStore, engine] in
            let settings = await settingsStore.load().chapterComments
            let snapshot = try? await sessionStore.snapshot()
            let profile = await profileStore.load()
            var viewer: ChapterCommentViewer?
            if let snapshot, await sessionStore.isCurrentGeneration(snapshot.generation) {
                viewer = ChapterCommentViewer(session: snapshot.session, profile: profile)
            }
            guard !Task.isCancelled else { return }
            do {
                let comments = try await engine.filter(page.comments, settings: settings, viewer: viewer)
                guard let self, !Task.isCancelled, generation == request else { return }
                var visiblePage = page
                visiblePage.comments = comments
                hasHiddenComments = comments.count < page.comments.count
                state = .loaded(target, visiblePage)
            } catch { /* Cancelled projections never replace a newer result. */ }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
