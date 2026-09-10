import Foundation
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite struct ForumContentRefreshStateTests {
    @Test func retainsChangesForOffscreenPagesAndDoesNotInvalidateOtherThreads() throws {
        let state = ForumContentRefreshState()
        let first = try change("action=reply&tid=704&fid=40")
        let second = try change("action=edit&tid=705&fid=41")
        state.record(first)
        state.record(second)
        #expect(state.threadChange("704") == first)
        #expect(state.threadChange("705") == second)
        #expect(state.threadChange("706") == nil)
        #expect(state.boardRevision("40") == first.id)
        #expect(state.boardRevision("41") == second.id)
        #expect(state.boardRevision("42") == nil)
        #expect(state.userSpaceRevision == second.id)
    }

    @Test func missingForumIDInvalidatesListsWithoutErasingThreadChanges() throws {
        let state = ForumContentRefreshState()
        let first = try change("action=newthread&tid=704&fid=40")
        let second = try change("action=reply&tid=705")
        state.record(first)
        state.record(second)
        #expect(state.boardRevision("40") == second.id)
        #expect(state.boardRevision("41") == second.id)
        #expect(state.threadChange("704") == first)
        let third = try change("action=edit&tid=704&fid=40")
        state.record(third)
        #expect(state.boardRevision("40") == third.id)
        #expect(state.boardRevision("41") == second.id)
    }

    @Test func accountResetDiscardsPendingRefreshes() throws {
        let state = ForumContentRefreshState()
        state.record(try change("action=edit&tid=704"))
        state.reset()
        #expect(state.threadChange("704") == nil)
        #expect(state.boardRevision("40") == nil)
        #expect(state.userSpaceRevision == nil)
    }

    private func change(_ query: String) throws -> ForumSubmissionChange {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&\(query)")!
        return try #require(ForumSubmissionChange(
            form: .init(id: "post", title: "Post", actionURL: url, kind: .thread), sourceURL: url,
            response: .init(url: url, title: "", message: "发表成功")
        ))
    }
}
