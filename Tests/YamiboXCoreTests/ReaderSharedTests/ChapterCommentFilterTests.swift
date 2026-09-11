import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ChapterCommentFilterTests {
    private let engine = ChapterCommentFilterEngine()

    @Test func defaultsAreExactAndGroupsAreIndependent() async throws {
        let phrases = ["你太可爱", "你太可愛", "好萌好萌好萌", "我很赞同", "我很贊同", "精品文章", "原创内容", "原創內容"]
        let comments = phrases.enumerated().map { comment(id: "\($0.offset)", body: $0.element) }
        #expect(try await engine.filter(comments, settings: .init(), viewer: nil).isEmpty)
        #expect(ChapterCommentFilterSettings() == ChapterCommentFilterSettings())
        let longer = comment(body: "我很赞同这个观点")
        let discussion = comment(source: .reply, body: "我很赞同")
        #expect(try await engine.filter([longer, discussion], settings: .init(), viewer: nil) == [longer, discussion])
        let settings = ChapterCommentFilterSettings(ratings: .init(), discussions: .init(isEnabled: true, rules: [.init(pattern: "赞同")]))
        #expect(try await engine.filter([longer, discussion], settings: settings, viewer: nil) == [longer])
    }

    @Test(arguments: [ChapterCommentSource.ratingReason, .postComment, .reply])
    func ownCommentsUseUIDBeforeVerifiedName(source: ChapterCommentSource) async throws {
        let settings = ChapterCommentFilterSettings(discussions: .init(isEnabled: true, rules: [.init(pattern: ".*")]))
        let comments = [comment(id: "uid", source: source, name: "Old name", uid: "1"),
                        comment(id: "name", source: source, name: "Me"),
                        comment(id: "conflict", source: source, name: "Me", uid: "2"),
                        comment(id: "partial", source: source, name: "Me Too"),
                        comment(id: "case", source: source, name: "me")]
        let viewer = ChapterCommentViewer(session: session(uid: "1"), profile: profile(uid: "1"))
        #expect(try await engine.filter(comments, settings: settings, viewer: viewer).map(\.id) == ["uid", "name"])
        let mismatched = ChapterCommentViewer(session: session(uid: "1"), profile: profile(uid: "2"))
        #expect(try await engine.filter(comments, settings: settings, viewer: mismatched).map(\.id) == ["uid"])
        let switched = ChapterCommentViewer(session: session(uid: "2"), profile: nil)
        #expect(try await engine.filter(comments, settings: settings, viewer: switched).map(\.id) == ["conflict"])
        #expect(try await engine.filter(comments, settings: settings, viewer: nil).isEmpty)
        #expect(ChapterCommentViewer(session: SessionState(), profile: profile(uid: "1")) == nil)
    }

    @Test func bodyOnlyAndEmoticonPlaceholderArePreserved() async throws {
        let bodyOnly = comment(name: "我很赞同", body: "Good")
        let smiley = ChapterComment(id: "smiley", source: .ratingReason, authorName: "Other", body: "我很赞同",
                                    bodyBlocks: [.init(text: "我很赞同\u{FFFC}")])
        #expect(try await engine.filter([bodyOnly, smiley], settings: .init(), viewer: nil) == [bodyOnly, smiley])
        #expect(try await engine.preview(pattern: #"\A我很赞同\z"#, text: "我很赞同\u{FFFC}") == .unmatched)
        #expect(try await engine.preview(pattern: #"\A我很赞同\z"#, text: "  我很赞同\n") == .matched)
    }

    @Test func invalidRulesFailOpenAndInlineOptionsWork() async throws {
        await #expect(throws: (any Error).self) { try await engine.validate(pattern: "[") }
        await #expect(throws: ChapterCommentPatternError.self) { try await engine.validate(pattern: " \n") }
        #expect(try await engine.preview(pattern: "hello", text: "HELLO") == .unmatched)
        #expect(try await engine.preview(pattern: "(?i)hello", text: "HELLO") == .matched)
        let comments = [comment(body: "HELLO")]
        var settings = ChapterCommentFilterSettings(ratings: .init(isEnabled: true, rules: [.init(pattern: "[")]))
        #expect(try await engine.filter(comments, settings: settings, viewer: nil) == comments)
        settings.ratings.rules.append(.init(pattern: "(?i)hello"))
        #expect(try await engine.filter(comments, settings: settings, viewer: nil).isEmpty)
        settings.ratings.rules = []
        #expect(try await engine.filter(comments, settings: settings, viewer: nil) == comments)
    }

    @Test func changedRuleVersionRecompilesWithoutChangingIdentity() async throws {
        let comments = [comment(body: "Good")]
        var settings = ChapterCommentFilterSettings(ratings: .init(isEnabled: true, rules: [.init(id: "stable", pattern: "Good")]))
        #expect(try await engine.filter(comments, settings: settings, viewer: nil).isEmpty)
        settings.ratings.rules[0].pattern = "Other"
        #expect(try await engine.filter(comments, settings: settings, viewer: nil) == comments)
    }

    @Test func timeBudgetPreservesAffectedCommentsAndCancellationThrows() async throws {
        let slow = String(repeating: "a", count: 30_000) + "!"
        #expect(try await engine.preview(pattern: "(a+)+$", text: slow) == .timedOut)
        let settings = ChapterCommentFilterSettings(ratings: .init(isEnabled: true, rules: [.init(pattern: "(a+)+$")]))
        let comments = [comment(id: "slow", body: slow), comment(id: "after", body: "aaa")]
        #expect(try await engine.filter(comments, settings: settings, viewer: nil) == comments)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.filter(comments, settings: settings, viewer: nil)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let running = Task { try await engine.preview(pattern: "(a+)+$", text: slow) }
        try await Task.sleep(for: .milliseconds(10))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let expired = ChapterCommentFilterEngine(matchBudget: .zero)
        #expect(try await expired.preview(pattern: ".*", text: "text") == .timedOut)
    }

    @Test func cancelledCompilationKeepsPreviousCachedVersionUsable() async throws {
        let comments = [comment(body: "original")]
        let original = ChapterCommentFilterSettings(ratings: .init(isEnabled: true, rules: [.init(pattern: "original")]))
        #expect(try await engine.filter(comments, settings: original, viewer: nil).isEmpty)
        let replacement = ChapterCommentFilterSettings(ratings: .init(isEnabled: true, rules: (0..<20_000).map {
            .init(pattern: "replacement-\($0)")
        }))
        let compilation = Task { try await engine.filter(comments, settings: replacement, viewer: nil) }
        try await Task.sleep(for: .milliseconds(2))
        compilation.cancel()
        await #expect(throws: CancellationError.self) { try await compilation.value }
        #expect(try await engine.filter(comments, settings: original, viewer: nil).isEmpty)
    }

    @Test func oldSettingsAndCommentsDecodeWithoutResettingExistingFields() throws {
        var settings = AppSettings()
        settings.novelReader.fontScale = 1.2
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        payload.removeValue(forKey: "chapterComments")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored == settings)
        let old = Data(#"{"id":"old","source":"reply","authorName":"Me","body":"Text"}"#.utf8)
        #expect(try JSONDecoder().decode(ChapterComment.self, from: old).authorUID == nil)
        settings.chapterComments.ratings.rules = []
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).chapterComments.ratings.rules.isEmpty)
    }

    @Test func commentRulesStayLocalWhenApplyingWebDAVSettings() {
        let local = AppSettings(chapterComments: .init(ratings: .init(), discussions: .init(isEnabled: true, rules: [.init(pattern: "local")])))
        let synced = WebDAVSyncedAppSettings(settings: local)
        #expect(synced == WebDAVSyncedAppSettings(settings: .init()))
        #expect(synced.applying(to: local).chapterComments == local.chapterComments)
    }

    private func comment(id: String = "test", source: ChapterCommentSource = .ratingReason,
                         name: String = "Other", uid: String? = nil, body: String = "我很赞同") -> ChapterComment {
        .init(id: id, source: source, authorName: name, body: body, authorUID: uid)
    }

    private func session(uid: String) -> SessionState {
        var session = SessionState(cookie: "\(SessionState.authenticationCookieName)=filter-test", isLoggedIn: true)
        session.accountUID = uid
        return session
    }

    private func profile(uid: String) -> YamiboProfile {
        .init(uid: uid, username: "Me", userGroup: "", points: 0, partner: 0, totalPoints: 0)
    }
}
