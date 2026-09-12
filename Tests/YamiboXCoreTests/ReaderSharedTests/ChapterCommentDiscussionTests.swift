import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ChapterCommentDiscussionTests {
    private let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", authorID: "1")

    @Test func desktopRepliesRatingsAndCommentsStayUnderTheirOwnPost() throws {
        let html = post("100", uid: "1", name: "Author", body: "Chapter")
            + post("101", body: "Root", extra: """
            <div id="comment_101"><div class="pstl"><div class="psta"><a href="space-uid-1.html">Author</a></div><div class="psti">Remark</div></div></div>
            <table id="ratelog_101"><tr><td><a>Rater</a></td><td>+2</td><td class="xg1">Rating</td></tr></table>
            """)
            + post("102", name: "Second", body: quote("101") + "Child")
            + post("103", uid: "1", name: "Author", body: quote("102") + "Author reply")
            + post("200", uid: "1", name: "Author", body: "Next chapter")
            + post("201", body: "Not in chapter")
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        #expect(page.isComplete)
        let discussion = try #require(page.discussions.first)
        #expect(page.discussions.count == 1)
        #expect(discussion.root.body == "Root")
        #expect(discussion.replies.map(\.comment.body) == ["Remark", "Rating", "Child", "Author reply"])
        #expect(discussion.replies.allSatisfy { $0.comment.quoteBlocks == nil })
        #expect(discussion.replies.last?.replyingToName == "Second")
        #expect(discussion.replies.last?.comment.isThreadAuthor == true)
        #expect(discussion.replies.first?.comment.isThreadAuthor == true)
        #expect(page.comments.first(where: { $0.postID == "103" })?.quoteBlocks != nil)
    }

    @Test func mobileAttachedCommentsIncludeRepliesToSubposts() throws {
        let html = """
        <div id="pid100"><ul class="authi"><li><a href="space-uid-1.html">Author</a></li></ul><div class="message">Chapter</div></div>
        <div id="pid101"><ul class="authi"><li><a href="space-uid-2.html">Reader</a></li></ul><div class="message">Root</div></div>
        <div id="pid102"><ul class="authi"><li><a href="space-uid-3.html">Second</a></li></ul><div class="message">\(quote("101"))Child</div>
        <div id="comment_102"><div id="commentdetail_55"><ul><li><a>Critic</a></li><li class="mtxt">Nested remark</li></ul></div></div>
        <div id="ratelog_102"><ul><li class="flex-box"><div><a>Rater</a></div><div>+5</div><div>Nested rating</div></li></ul></div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        let discussion = try #require(page.discussions.first)
        #expect(discussion.replies.map(\.comment.body) == ["Child", "Nested remark", "Nested rating"])
        #expect(discussion.replies.map(\.replyingToName) == [nil, "Second", "Second"])
    }

    @Test func laterChapterRetainsEarlierReplyQuoteAndOwnDescendants() throws {
        let html = post("100", uid: "1", name: "Author", body: "Chapter")
            + post("101", name: "Later", body: quote("50") + "Cross chapter")
            + post("102", body: quote("101") + "Local child")
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        let discussion = try #require(page.discussions.first)
        #expect(discussion.root.quoteBlocks?.count == 1)
        #expect(discussion.root.body == "Cross chapter")
        #expect(discussion.replies.count == 1)
        #expect(discussion.replies.first?.comment.quoteBlocks == nil)
    }

    @Test func pageMergeResolvesEarlierParentWithoutDuplicates() throws {
        var page = try ChapterCommentsHTMLParser.parseInitialPage(
            html: post("100", uid: "1", body: "Chapter") + post("101", body: "Root"), target: target, isUnfiltered: true
        )
        let next = try ChapterCommentsHTMLParser.parseContinuationPage(html: post("102", body: quote("101") + "Child"), target: target, view: 2)
        page.append(next)
        page.append(next)
        #expect(page.comments.count == 2)
        #expect(page.discussions.count == 1)
        #expect(page.discussions.first?.replies.first?.comment.body == "Child")
    }

    @Test func headerFallbackRequiresUniqueNameAndTime() throws {
        let time = "2026-9-12 10:30"
        let header = "<div class='quote'><blockquote>Reader 发表于 \(time)<br>Old text</blockquote></div>"
        let owner = post("100", uid: "1", body: "Chapter")
        let first = post("101", body: "Root", time: time)
        let reply = post("103", body: header + "Child")
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: owner + first + reply, target: target, isUnfiltered: true)
        #expect(page.discussions.count == 1)
        let ambiguous = try ChapterCommentsHTMLParser.parseInitialPage(
            html: owner + first + post("102", body: "Same minute", time: time) + reply, target: target, isUnfiltered: true
        )
        #expect(ambiguous.discussions.count == 3)
        #expect(ambiguous.discussions.last?.root.quoteBlocks != nil)
    }

    @Test func ordinaryQuotationDoesNotTurnAuthorChapterIntoDiscussion() throws {
        let html = post("100", uid: "1", body: "Chapter")
            + post("101", body: "Root")
            + post("200", uid: "1", body: "Next chapter<div class='quote'><blockquote>Literary quotation</blockquote></div>")
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        #expect(page.isBoundaryClosed)
        #expect(page.comments.map(\.postID) == ["101"])
    }

    @Test func hiddenQuotesNeitherLeakNorCreateReplyRelationships() throws {
        let hidden = "<div hidden>\(quote("101"))</div>"
        let page = try ChapterCommentsHTMLParser.parseInitialPage(
            html: post("100", uid: "1", body: "Chapter") + post("101", body: "Root")
                + post("102", body: hidden + "Independent") + post("200", uid: "1", body: hidden + "Next chapter"),
            target: target, isUnfiltered: true
        )
        #expect(page.discussions.count == 2)
        #expect(page.discussions.last?.root.replyReference == nil)
        #expect(page.discussions.last?.root.quoteBlocks == nil)
        #expect(page.isBoundaryClosed)
    }

    @Test func filteredAncestorsDoNotHideOrDetachVisibleDescendants() {
        let comments = [comment("101"), comment("102", parent: "101"), comment("103", parent: "102")]
        let groups = ChapterCommentDiscussion.group(comments, target: target)
        let filtered = groups.compactMap { $0.filtering(visibleIDs: ["103"]) }
        #expect(filtered.count == 1)
        #expect(filtered.first?.root.isFiltered == true)
        #expect(filtered.first?.root.body == "")
        #expect(filtered.first?.replies.map(\.id) == ["103"])
        #expect(filtered.first?.replies.first?.replyingToName == "User102")
        #expect(groups.first?.root.body == "Body101")
    }

    @Test func cyclesAndMissingParentsNeverDiscardComments() {
        let groups = ChapterCommentDiscussion.group([comment("101", parent: "102"), comment("102", parent: "101"), comment("103", parent: "9")], target: target)
        #expect(groups.map(\.id) == ["101", "102", "103"])
        #expect(groups.allSatisfy { $0.conversations.isEmpty })
    }

    @Test func conversationsIncludeTheWholeBranchWithoutTheDiscussionRootOrOtherBranches() throws {
        let comments = [comment("101"), comment("102", parent: "101"), comment("103", parent: "102"),
                        comment("104", parent: "103"), comment("105", parent: "101"), comment("106", parent: "105"),
                        comment("107", parent: "102"),
                        ChapterComment(id: "remark", source: .postComment, authorName: "Critic", body: "Remark", postID: "103"),
                        ChapterComment(id: "rating", source: .ratingReason, authorName: "Rater", body: "Rating", postID: "102")]
        let discussion = try #require(ChapterCommentDiscussion.group(comments, target: target).first)
        let conversation = try #require(discussion.conversations.first { $0.id == "102" })
        #expect(conversation.root.id == "102")
        #expect(conversation.replies.map(\.id) == ["103", "104", "107", "remark", "rating"])
        #expect(conversation.replies.map(\.parentCommentID) == ["102", "103", "102", "103", "102"])
        #expect(conversation.replies.allSatisfy { $0.conversationRootID == "102" })
        #expect(discussion.conversations.last?.replies.map(\.id) == ["106"])
    }

    @Test func conversationsPreserveHiddenBranchRootWithoutExposingItsBody() throws {
        let discussion = try #require(ChapterCommentDiscussion.group(
            [comment("101"), comment("102", parent: "101"), comment("103", parent: "102"), comment("104", parent: "103")],
            target: target
        ).first)
        let filtered = try #require(discussion.filtering(visibleIDs: ["101", "104"]))
        let conversation = try #require(filtered.conversations.first)
        #expect(conversation.id == "102")
        #expect(conversation.root.isFiltered == true)
        #expect(conversation.root.body.isEmpty)
        #expect(conversation.root.bodyBlocks == nil && conversation.root.contentBlocks == nil && conversation.root.quoteBlocks == nil)
        #expect(conversation.replies.map(\.id) == ["104"])
        #expect(conversation.replies.first?.replyingToName == "User103")
        #expect(discussion.filtering(visibleIDs: ["101"])?.conversations.isEmpty == true)
    }

    @Test func appendedRepliesKeepTheSameConversationIdentity() throws {
        var page = ChapterCommentsPage(target: target, comments: [comment("101"), comment("102", parent: "101"), comment("103", parent: "102")], isBoundaryClosed: false, nextView: 2)
        let initial = try #require(page.discussions.first?.conversations.first)
        page.append(.init(target: target, comments: [comment("104", parent: "103")], isBoundaryClosed: true))
        let updated = try #require(page.discussions.first?.conversations.first)
        #expect(initial.id == updated.id)
        #expect(updated.replies.map(\.id) == ["103", "104"])
    }

    @Test func oldRecordsDecodeWithNoInventedRelations() throws {
        let json = Data(#"{"id":"1","source":"reply","authorName":"Reader","body":"Body"}"#.utf8)
        let value = try JSONDecoder().decode(ChapterComment.self, from: json)
        #expect(value.replyReference == nil)
        #expect(value.quoteBlocks == nil)
        #expect(value.isThreadAuthor == nil)
        #expect(try JSONDecoder().decode(ChapterComment.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func imageOnlyAndQuotedOnlyRepliesAreRetained() throws {
        let html = post("100", uid: "1", body: "Chapter") + post("101", body: "<img src='/photo.jpg'>")
            + post("102", body: quote("999"))
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        #expect(page.discussions.count == 2)
        #expect(page.discussions.first?.root.contentBlocks?.count == 1)
        #expect(page.discussions.last?.root.quoteBlocks?.count == 1)
    }

    @Test func continuationRejectsServerReturningAnotherPage() {
        #expect(throws: ReaderChapterCommentsUnavailableError.self) {
            try ChapterCommentsHTMLParser.parseContinuationPage(html: "<div class='pg'><strong>1</strong></div>" + post("101", body: "Repeated"), target: target, view: 2)
        }
        #expect(throws: ReaderChapterCommentsUnavailableError.self) {
            try ChapterCommentsHTMLParser.parseContinuationPage(html: "<div>Temporarily unavailable</div>", target: target, view: 2)
        }
    }

    @Test func mobilePageSelectorResolvesUnfilteredCursorAndRejectsRepeatedPage() throws {
        let navigation = "<select id='dumppage'><option value='4' selected>4</option><option value='5'>5</option></select>"
        #expect(try ChapterCommentsHTMLParser.currentView(html: navigation, fallback: 1) == 4)
        #expect(throws: ReaderChapterCommentsUnavailableError.self) {
            try ChapterCommentsHTMLParser.parseContinuationPage(html: navigation + post("101", body: "Repeated"), target: target, view: 5)
        }
    }

    @Test func removedSettingDoesNotResetOtherPreferences() throws {
        var settings = NovelReaderAppearanceSettings(fontScale: 1.3, loadsInlineImages: false)
        settings.readingMode = .vertical
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        for legacy in [true, false] {
            json["showsAuthorRepliesToOthers"] = legacy
            let decoded = try JSONDecoder().decode(NovelReaderAppearanceSettings.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded == settings)
        }
    }

    @Test func novelProjectionSharesReplyDetectionForHTMLAndTypedSourceCaches() throws {
        for useHTML in [true, false] {
            let replyHTML = quote("101") + "<img src='/reply-photo.jpg'>"
            let ordinaryHTML = "Next chapter<div class='quote'><blockquote>Literary quotation</blockquote></div>"
            let posts = try [("102", replyHTML), ("200", ordinaryHTML)].map { pid, html in
                ForumThreadPost(
                    postID: pid, author: .init(uid: "1", name: "Author"),
                    contentHTML: useHTML ? html : "", contentText: "Cached flattened text",
                    contentBlocks: try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: html)
                )
            }
            let projection = try NovelReaderProjectionBuilder.build(
                from: .init(thread: .init(tid: "42"), title: "Thread", posts: posts),
                request: .init(threadID: "42", view: 1, authorID: "1"), authorID: "1"
            )
            let replySources = projection.segmentSources.compactMap { $0 }.filter { $0.ownerPostID == "102" }
            #expect(!replySources.isEmpty)
            #expect(replySources.allSatisfy { $0.isAuthorReplyToOther })
            #expect(projection.retainedChapterCount == 1)
            #expect(projection.filteredChapterCandidateCount == 1)
            let directory = NovelChapterDirectoryExtractor.entries(from: projection, settings: .init())
            #expect(directory.count == 1)
        }
    }

    private func comment(_ pid: String, parent: String? = nil) -> ChapterComment {
        .init(id: pid, source: .reply, authorName: "User" + pid, body: "Body" + pid, postID: pid,
              replyReference: parent.map { .init(postID: $0) })
    }

    private func post(_ pid: String, uid: String = "2", name: String = "Reader", body: String, extra: String = "", time: String = "2026-9-12 10:30") -> String {
        "<div id='post_\(pid)'><div class='authi'><a href='space-uid-\(uid).html'>\(name)</a><em>发表于 \(time)</em></div><div id='postmessage_\(pid)'>\(body)</div>\(extra)</div>"
    }

    private func quote(_ pid: String) -> String {
        "<div class='quote'><blockquote><a href='forum.php?mod=redirect&amp;goto=findpost&amp;ptid=42&amp;pid=\(pid)'>Reader 发表于 2026-9-12 10:30</a><br>Quoted text</blockquote></div>"
    }
}

@MainActor @Suite struct ChapterCommentBackgroundLoadingTests {
    private let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100")

    @Test func firstBatchIsPublishedWhileNextPageIsSuspended() async throws {
        let first = page("101", next: 2)
        let next = page("102", parent: "101")
        let gate = CommentPageGate()
        let module = ReaderChapterCommentsModule(adapter: .init(loadInitial: { _ in first }, loadMore: { _, _ in try await gate.load() }), onChange: nil)
        let task = Task { await module.loadAndContinue(target) }
        await gate.waitUntilStarted()
        guard case let .loaded(_, partial) = module.state else { Issue.record("First batch not published"); return }
        #expect(partial.comments.map(\.id) == ["101"])
        #expect(module.isLoadingMore)
        await module.continueLoading()
        #expect(await gate.calls == 1)
        await gate.finish(next)
        await task.value
        guard case let .loaded(_, complete) = module.state else { Issue.record("Missing result"); return }
        #expect(complete.isComplete)
        #expect(complete.discussions.count == 1)
        #expect(complete.discussions.first?.replies.map(\.id) == ["102"])
    }

    @Test func failedOrNonAdvancingPageStopsAndRetriesItsCursor() async {
        let first = page("101", next: 2)
        let bad = page("102", next: 2)
        let good = page("102")
        let source = CommentPageSequence([.failure(URLError(.timedOut)), .success(bad), .success(good)])
        let module = ReaderChapterCommentsModule(adapter: .init(loadInitial: { _ in first }, loadMore: { _, view in try await source.load(view) }), onChange: nil)
        await module.loadAndContinue(target)
        #expect(module.loadMoreError != nil)
        await module.continueLoading()
        #expect(module.loadMoreError != nil)
        guard case let .loaded(_, partial) = module.state else { Issue.record("Missing partial result"); return }
        #expect(partial.comments.count == 1)
        #expect(partial.nextView == 2)
        await module.continueLoading()
        guard case let .loaded(_, result) = module.state else { Issue.record("Missing result"); return }
        #expect(result.isComplete)
        #expect(result.comments.count == 2)
        #expect(await source.views == [2, 2, 2])
    }

    @Test func missingChapterStartDoesNotScanUnrelatedLaterPages() async {
        var incomplete = page("101", next: 2)
        incomplete.needsInitialRetry = true
        let initial = incomplete
        let source = CommentPageSequence([])
        let module = ReaderChapterCommentsModule(adapter: .init(
            loadInitial: { _ in initial }, loadMore: { _, view in try await source.load(view) }
        ), onChange: nil)
        await module.loadAndContinue(target)
        #expect(await source.views.isEmpty)
        #expect(module.state == .loaded(target, initial))
        #expect(!initial.isComplete)
    }

    @Test func cancelledLoadKeepsCacheAndIgnoresLatePage() async {
        let first = page("101", next: 2)
        let next = page("102")
        let gate = CommentPageGate()
        let module = ReaderChapterCommentsModule(adapter: .init(loadInitial: { _ in first }, loadMore: { _, _ in try await gate.load() }), onChange: nil)
        let task = Task { await module.loadAndContinue(target) }
        await gate.waitUntilStarted()
        task.cancel()
        module.cancelLoading()
        await gate.finish(next)
        await task.value
        guard case let .loaded(_, retained) = module.state else { Issue.record("Missing cache"); return }
        #expect(retained.nextView == 2)
        #expect(retained.comments.count == 1)
        #expect(module.loadMoreError == nil)
        let reopened = Task { await module.loadAndContinue(target) }
        await gate.waitUntilStarted()
        await gate.finish(next)
        await reopened.value
        guard case let .loaded(_, complete) = module.state else { Issue.record("Missing result"); return }
        #expect(complete.isComplete)
    }

    @Test func incompleteRatingsRetryWithoutReloadingThreadPages() async throws {
        let request = ChapterCommentRatingRequest(postID: "101", url: try #require(URL(string: "https://bbs.yamibo.com/ratings")))
        let preview = ChapterComment(id: "preview", source: .ratingReason, authorName: "Rater", body: "Preview", postID: "101", authorUID: "7")
        var first = page("101")
        first.comments.append(preview)
        first.pendingRatings = [request]
        let initial = first
        let source = CommentPageSequence([.failure(URLError(.timedOut)), .success(.init(target: target, comments: [.init(id: "full", source: .ratingReason, authorName: "Rater", body: "Full", postID: "101")], isBoundaryClosed: true))])
        let module = ReaderChapterCommentsModule(adapter: .init(loadInitial: { _ in initial }, loadMore: { _, _ in throw URLError(.badURL) }, loadRatings: { _, _ in try await source.load(0).comments }), onChange: nil)
        await module.loadAndContinue(target)
        guard case let .loaded(_, partial) = module.state else { Issue.record("Missing partial result"); return }
        #expect(!partial.isComplete)
        #expect(partial.comments.last?.body == "Preview")
        await module.continueLoading()
        guard case let .loaded(_, complete) = module.state else { Issue.record("Missing result"); return }
        #expect(complete.isComplete)
        #expect(complete.comments.last?.body == "Full")
        #expect(complete.comments.last?.authorUID == "7")
    }

    @Test func lateRefreshCannotResumeCachedPaginationDuringNewerRefresh() async {
        let cached = page("101", next: 2)
        let stale = page("stale", next: 2)
        let fresh = page("fresh")
        let oldGate = CommentPageGate()
        let newGate = CommentPageGate()
        let source = RefreshRaceSource(initial: cached, oldGate: oldGate, newGate: newGate)
        let pages = CommentPageSequence([])
        let module = ReaderChapterCommentsModule(adapter: .init(
            loadInitial: { _ in try await source.load() }, loadMore: { _, view in try await pages.load(view) }
        ), onChange: nil)
        await module.load(target)
        let old = Task { await module.refreshAndContinue(target) }
        await oldGate.waitUntilStarted()
        let new = Task { await module.refreshAndContinue(target) }
        await newGate.waitUntilStarted()
        await oldGate.finish(stale)
        await old.value
        #expect(await pages.views.isEmpty)
        await newGate.finish(fresh)
        await new.value
        guard case let .loaded(_, result) = module.state else { Issue.record("Missing result"); return }
        #expect(result.comments.map(\.id) == ["fresh"])
    }

    @Test func switchingChapterRejectsUncancelledLateContinuation() async {
        let first = page("101", next: 2)
        let stale = page("102")
        let other = ReaderChapterCommentTarget(threadID: "42", view: 4, ownerPostID: "200")
        let fresh = ChapterCommentsPage(target: other, comments: [], isBoundaryClosed: true)
        let gate = CommentPageGate()
        let module = ReaderChapterCommentsModule(adapter: .init(
            loadInitial: { requested in requested == other ? fresh : first },
            loadMore: { _, _ in try await gate.load() }
        ), onChange: nil)
        let old = Task { await module.loadAndContinue(target) }
        await gate.waitUntilStarted()
        await module.loadAndContinue(other)
        await gate.finish(stale)
        await old.value
        #expect(module.state == .loaded(other, fresh))
    }

    private func page(_ pid: String, next: Int? = nil, parent: String? = nil) -> ChapterCommentsPage {
        .init(target: target, comments: [.init(id: pid, source: .reply, authorName: "Reader", body: pid, postID: pid, replyReference: parent.map { .init(postID: $0) })], isBoundaryClosed: next == nil, nextView: next)
    }
}

private actor CommentPageGate {
    private var pending: CheckedContinuation<ChapterCommentsPage, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func load() async throws -> ChapterCommentsPage {
        calls += 1
        return try await withCheckedThrowingContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ page: ChapterCommentsPage) {
        pending?.resume(returning: page)
        pending = nil
    }
}

private actor CommentPageSequence {
    var results: [Result<ChapterCommentsPage, any Error>]
    private(set) var views: [Int] = []
    init(_ results: [Result<ChapterCommentsPage, any Error>]) { self.results = results }
    func load(_ view: Int) throws -> ChapterCommentsPage {
        views.append(view)
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return try results.removeFirst().get()
    }
}

private actor RefreshRaceSource {
    let initial: ChapterCommentsPage
    let oldGate: CommentPageGate
    let newGate: CommentPageGate
    var calls = 0
    init(initial: ChapterCommentsPage, oldGate: CommentPageGate, newGate: CommentPageGate) {
        self.initial = initial
        self.oldGate = oldGate
        self.newGate = newGate
    }
    func load() async throws -> ChapterCommentsPage {
        calls += 1
        if calls == 1 { return initial }
        return try await (calls == 2 ? oldGate : newGate).load()
    }
}
