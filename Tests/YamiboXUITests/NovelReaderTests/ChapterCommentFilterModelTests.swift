import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ChapterCommentFilterModelTests: XCTestCase {
    func testCachedRawPageRefiltersAfterSettingsAndAccountChanges() async throws {
        let fixture = try makeSystemSettingsFixture()
        let context = fixture.appContext
        let model = ChapterCommentFilterModel(settingsStore: fixture.settingsStore,
                                              sessionStore: context.sessionStore, profileStore: context.profileStore)
        let target = ReaderChapterCommentTarget(threadID: "1", view: 1, ownerPostID: "100", title: "Chapter")
        let raw = ChapterCommentsPage(target: target, comments: [
            .init(id: "own", source: .ratingReason, authorName: "Me", body: "我很赞同", authorUID: "1"),
            .init(id: "other", source: .ratingReason, authorName: "Other", body: "我很赞同", authorUID: "2"),
            .init(id: "name", source: .ratingReason, authorName: "Me", body: "我很赞同")
        ], isBoundaryClosed: false, nextView: 2)
        model.update(.loaded(target, raw))
        try await waitForSettings { if case .loaded = model.state { true } else { false } }
        XCTAssertEqual(visibleIDs(model), [])
        if case let .loaded(_, page) = model.state { XCTAssertEqual(page.nextView, 2) }
        XCTAssertTrue(model.hasHiddenComments)

        var session = SessionState(cookie: "\(SessionState.authenticationCookieName)=filter-test", isLoggedIn: true)
        session.accountUID = "1"
        try await context.sessionStore.save(session)
        try await context.profileStore.save(.init(uid: "1", username: "Me", userGroup: "", points: 0, partner: 0, totalPoints: 0))
        model.refresh()
        try await waitForSettings { self.visibleIDs(model) == ["own", "name"] }

        session.accountUID = "2"
        try await context.sessionStore.save(session)
        model.refresh()
        try await waitForSettings { self.visibleIDs(model) == ["other"] }
        try await context.sessionStore.reset()
        model.refresh()
        try await waitForSettings { self.visibleIDs(model) == [] }

        try await fixture.settingsStore.update { $0.chapterComments.ratings.rules = [] }
        model.refresh()
        try await waitForSettings { self.visibleIDs(model) == ["own", "other", "name"] }
        XCTAssertEqual(raw.comments.count, 3)
        XCTAssertFalse(model.hasHiddenComments)
    }

    func testCancelledProjectionCannotOverwriteNewChapter() async throws {
        let fixture = try makeSystemSettingsFixture()
        let model = ChapterCommentFilterModel(settingsStore: fixture.settingsStore,
                                              sessionStore: fixture.appContext.sessionStore,
                                              profileStore: fixture.appContext.profileStore)
        try await fixture.settingsStore.update {
            $0.chapterComments.ratings.rules = [.init(pattern: "(a+)+$")]
        }
        let first = ReaderChapterCommentTarget(threadID: "1", view: 1, ownerPostID: "100", title: "First")
        let second = ReaderChapterCommentTarget(threadID: "1", view: 1, ownerPostID: "200", title: "Second")
        model.update(.loaded(first, .init(target: first, comments: [
            .init(id: "old", source: .ratingReason, authorName: "Other", body: String(repeating: "a", count: 30_000) + "!")
        ], isBoundaryClosed: false)))
        model.update(.loaded(second, .init(target: second, comments: [], isBoundaryClosed: true)))
        try await waitForSettings {
            if case let .loaded(target, _) = model.state { target == second } else { false }
        }
        XCTAssertEqual(visibleIDs(model), [])
        model.cancel()
    }

    func testConversationProjectionRefiltersWithoutLosingItsBranchIdentity() async throws {
        let fixture = try makeSystemSettingsFixture()
        let model = ChapterCommentFilterModel(settingsStore: fixture.settingsStore,
                                              sessionStore: fixture.appContext.sessionStore,
                                              profileStore: fixture.appContext.profileStore)
        let target = ReaderChapterCommentTarget(threadID: "1", view: 1, ownerPostID: "100")
        let raw = ChapterCommentsPage(target: target, comments: [
            .init(id: "root", source: .reply, authorName: "A", body: "Root", postID: "101"),
            .init(id: "branch", source: .reply, authorName: "B", body: "Hidden branch", postID: "102", replyReference: .init(postID: "101")),
            .init(id: "child", source: .reply, authorName: "C", body: "Visible child", postID: "103", replyReference: .init(postID: "102"))
        ], isBoundaryClosed: false, nextView: 2)
        model.update(.loaded(target, raw))
        try await waitForSettings { model.discussions.first?.conversations.first?.root.body == "Hidden branch" }
        try await fixture.settingsStore.update {
            $0.chapterComments.discussions = .init(isEnabled: true, rules: [.init(pattern: "^Hidden branch$")])
        }
        model.refresh()
        try await waitForSettings { model.discussions.first?.conversations.first?.root.isFiltered == true }
        let conversation = try XCTUnwrap(model.discussions.first?.conversations.first)
        XCTAssertEqual(conversation.id, "branch")
        XCTAssertEqual(conversation.root.body, "")
        XCTAssertEqual(conversation.replies.map(\.id), ["child"])
        try await fixture.settingsStore.update { $0.chapterComments.discussions.rules = [.init(pattern: "Hidden branch|Visible child")] }
        model.refresh()
        try await waitForSettings { model.discussions.first?.conversations.isEmpty == true }
        try await fixture.settingsStore.update { $0.chapterComments.discussions.rules = [] }
        model.refresh()
        try await waitForSettings { model.discussions.first?.conversations.first?.root.body == "Hidden branch" }
        XCTAssertEqual(model.discussions.first?.conversations.first?.id, "branch")
        try await fixture.settingsStore.update { $0.chapterComments.discussions.rules = [.init(pattern: "^Hidden branch$")] }
        var complete = raw
        complete.nextView = nil
        complete.isBoundaryClosed = true
        model.update(.loaded(target, complete))
        try await waitForSettings { model.discussions.first?.conversations.first?.root.isFiltered == true }
        let previousState = model.state
        complete.comments.removeAll { $0.id == "branch" }
        model.update(.loaded(target, complete))
        try await waitForSettings { model.discussions.map(\.id) == ["root", "child"] }
        XCTAssertEqual(model.state, previousState)
        model.cancel()
    }

    private func visibleIDs(_ model: ChapterCommentFilterModel) -> [String]? {
        guard case let .loaded(_, page) = model.state else { return nil }
        return page.comments.map(\.id)
    }
}
