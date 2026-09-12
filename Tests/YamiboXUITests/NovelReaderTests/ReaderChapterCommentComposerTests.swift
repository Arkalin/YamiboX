import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
@Suite
struct ReaderChapterCommentComposerTests {
    private let chapter = ReaderChapterCommentTarget(threadID: "123", view: 2, ownerPostID: "456", title: "Chapter", authorID: "42")

    @Test func entryTargetsOnlyIndependentPostsAndDefaultsToComment() throws {
        let owner = try #require(ReaderChapterCommentComposeTarget.owner(chapter))
        #expect(owner.initialMode == .comment)
        for source in [ChapterCommentSource.postComment, .ratingReason] {
            #expect(ReaderChapterCommentComposeTarget.reply(ChapterComment(id: "a", source: source, authorName: "Reader", body: "Text", postID: "456"), chapter: chapter) == nil)
        }
        let reply = try #require(ReaderChapterCommentComposeTarget.reply(ChapterComment(id: "r", source: .reply, authorName: "Reader", body: "Text", postID: "789"), chapter: chapter))
        #expect(reply.postID == "789")
        #expect(reply.initialMode == .reply)
        #expect(!reply.isChapterOwner)
        #expect(ReaderChapterCommentComposeTarget.reply(ChapterComment(id: "r", source: .reply, authorName: "Reader", body: "Text"), chapter: chapter) == nil)
    }

    @Test func modeSwitchPreservesIndependentDraftsAndTarget() async throws {
        let harness = try makeHarness()
        let model = harness.model
        await model.load()
        #expect(model.authorName == "Author")
        #expect(model.mode == .comment)
        #expect(!model.canSubmit)
        model.comment?.message = "点评论文"
        model.selectMode(.rating)
        await model.loadMode()
        model.rating?.scoreText = " 2 "
        model.rating?.reason = "Rating reason"
        model.rating?.noticeAuthor = true
        #expect(model.canSubmit)
        model.selectMode(.reply)
        await model.loadMode()
        let session = try #require(model.replySession)
        let form = try #require(model.replyForm)
        let field = try #require(form.fields.first { $0.name == "message" })
        #expect(!model.canSubmit, "The server's initial quote alone is not a reply")
        session.drafts[form.id]?[field.id] = ["[quote]Source[/quote]中文回复"]
        #expect(model.canSubmit)
        model.selectMode(.comment)
        #expect(model.comment?.message == "点评论文")
        #expect(model.rating?.reason == "Rating reason")
        #expect(model.rating?.noticeAuthor == true)
        #expect(session.drafts[form.id]?[field.id] == ["[quote]Source[/quote]中文回复"])
        #expect(model.target.postID == "456")
        #expect(model.context?.page == 9)
        #expect(model.hasEdits)
        #expect(await harness.repository.loads == 1)
    }

    @Test func commentsUseVerifiedPostAndUnfilteredPage() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.comment?.message = "  "
        #expect(await harness.model.submit() == nil)
        harness.model.comment?.message = "A comment"
        let feedback = await harness.model.submit()
        #expect(feedback?.message == "点评成功")
        #expect(harness.record.contexts.map(\.page) == [9])
        #expect(harness.record.contexts.map(\.post.postID) == ["456"])
        #expect(harness.model.didSubmit)
        #expect(!harness.model.hasEdits)
        #expect(await harness.model.submit() == nil)
        #expect(harness.record.contexts.count == 1)
    }

    @Test func ratingValidatesServerChoicesAndRetainsDraftAfterFailure() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.selectMode(.rating)
        await harness.model.loadMode()
        for invalid in ["", "abc", "0", "99"] {
            harness.model.rating?.scoreText = invalid
            #expect(!harness.model.canSubmit)
            #expect(await harness.model.submit() == nil)
        }
        harness.model.rating?.scoreText = "2"
        harness.model.rating?.reason = "Reason"
        harness.record.fails = true
        #expect(await harness.model.submit() == nil)
        #expect(harness.model.rating?.errorMessage != nil)
        #expect(harness.model.rating?.reason == "Reason")
        #expect(!harness.model.didSubmit)
        harness.record.fails = false
        #expect(await harness.model.submit()?.message == "评分成功")
    }

    @Test func blockedContextNeverCreatesReplySessionOrSubmits() async throws {
        let harness = try makeHarness()
        harness.record.fails = true
        await harness.model.load()
        #expect(harness.model.context == nil)
        #expect(harness.model.replySession == nil)
        #expect(harness.model.feedback != nil)
        #expect(harness.model.authorName == L10n.string("forum.thread.unknown_author"))
        #expect(await harness.model.submit() == nil)
        #expect(harness.record.contexts.isEmpty)
        harness.record.fails = false
        await harness.model.load(retry: true)
        #expect(harness.model.context?.post.postID == "456")
        #expect(harness.model.authorName == "Author")
        #expect(harness.model.feedback == nil)
    }

    @Test func retryContextPreservesDraftAndUsesFreshPage() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.comment?.message = "Keep draft"
        harness.record.page = 10
        await harness.model.load(retry: true)
        #expect(harness.model.comment?.message == "Keep draft")
        #expect(await harness.model.submit() != nil)
        #expect(harness.record.contexts.first?.page == 10)
    }

    @Test(arguments: [true, false]) func contextFailureKeepsRecoveryAcrossModes(authentication: Bool) async throws {
        let harness = try makeHarness()
        harness.record.contextError = authentication ? YamiboError.notAuthenticated : YamiboError.parsingFailed(context: "post")
        await harness.model.load()
        for mode in ReaderChapterCommentComposeMode.allCases {
            harness.model.selectMode(mode)
            await harness.model.loadMode()
            #expect(harness.model.context == nil)
            #expect(harness.model.feedback?.details?.requiresAuthentication == authentication)
            #expect(!harness.model.canSubmit)
        }
    }

    @Test func ratingRejectionSurvivesModeSwitchUntilExplicitRetry() async throws {
        let harness = try makeHarness()
        harness.record.optionsError = YamiboError.underlying("抱歉，您不能给自己发表的帖子评分")
        await harness.model.load()
        harness.model.selectMode(.rating)
        await harness.model.loadMode()
        harness.model.rating?.scoreText = "2"
        #expect(!harness.model.canSubmit)
        #expect(!harness.model.hasSubmissionFailure)
        harness.model.selectMode(.comment)
        harness.model.comment?.message = "Can still comment"
        #expect(harness.model.canSubmit)
        harness.model.selectMode(.rating)
        await harness.model.loadMode()
        #expect(harness.record.optionLoads == 1)
        #expect(harness.model.rating?.optionsFailure != nil)
        #expect(harness.model.rating?.optionsFailure?.details?.requiresAuthentication == false)
        #expect(!harness.model.canSubmit)
        harness.record.optionsError = nil
        await harness.model.load(retry: true)
        #expect(harness.record.optionLoads == 2)
        #expect(harness.model.rating?.optionsFailure == nil)
        #expect(harness.model.canSubmit)
    }

    @Test(arguments: ReaderChapterCommentComposeMode.allCases, [true, false])
    func submissionLoginRecoveryUsesOnlyActiveTypedError(mode: ReaderChapterCommentComposeMode, authentication: Bool) async throws {
        let harness = try makeHarness()
        let error: any Error = authentication ? YamiboError.notAuthenticated : YamiboError.underlying("暂时无法发表")
        harness.record.submissionError = error
        await harness.repository.setSubmissionError(error)
        await harness.model.load()
        harness.model.selectMode(mode)
        await harness.model.loadMode()
        switch mode {
        case .rating: harness.model.rating?.scoreText = "2"
        case .comment: harness.model.comment?.message = "Keep comment"
        case .reply:
            let form = try #require(harness.model.replyForm)
            harness.model.replySession?.drafts[form.id]?["message"] = ["Keep reply"]
        }
        #expect(await harness.model.submit() == nil)
        #expect(harness.model.hasSubmissionFailure)
        #expect(harness.model.submissionRequiresAuthentication == authentication)
        #expect(harness.model.hasEdits)
        harness.model.selectMode(mode == .comment ? .rating : .comment)
        #expect(!harness.model.hasSubmissionFailure)
        #expect(!harness.model.submissionRequiresAuthentication)
    }

    @Test func submissionBlocksModeSwitchAndDuplicateRequest() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.comment?.message = "Once"
        harness.record.suspends = true
        let first = Task { await harness.model.submit() }
        for _ in 0 ..< 100 where harness.record.continuation == nil { await Task.yield() }
        #expect(harness.model.isBusy)
        harness.model.selectMode(.reply)
        #expect(harness.model.mode == .comment)
        #expect(await harness.model.submit() == nil)
        harness.record.continuation?.resume()
        #expect(await first.value != nil)
        #expect(harness.record.contexts.count == 1)
    }

    @Test func uploadingBlocksModeSwitchAndSubmission() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.comment?.message = "Keep"
        harness.model.isPreparingAttachment = true
        harness.model.selectMode(.reply)
        #expect(harness.model.mode == .comment)
        #expect(!harness.model.canSubmit)
        #expect(await harness.model.submit() == nil)
    }

    @Test func replySubmitsWithoutPendingConfirmationAndKeepsModerationMessage() async throws {
        let harness = try makeHarness()
        await harness.repository.setMessage("回复已进入审核")
        await harness.model.load()
        harness.model.selectMode(.reply)
        await harness.model.loadMode()
        let session = try #require(harness.model.replySession)
        let form = try #require(harness.model.replyForm)
        session.drafts[form.id]?["message"] = ["[quote]Source[/quote]Reply"]
        let result = await harness.model.submit()
        #expect(result?.message == "回复已进入审核")
        #expect(session.pendingSubmission == nil)
        #expect(await harness.repository.submissions == 1)
        #expect(harness.model.didSubmit)
        #expect(session.url.queryItemValue("repquote") == "456")
        #expect(session.url.queryItemValue("page") == "9")
    }

    @Test func ambiguousReplyAndCancellationDoNotDismissOrClearDraft() async throws {
        let harness = try makeHarness()
        await harness.repository.setMessage("请稍后查看")
        await harness.model.load()
        harness.model.selectMode(.reply)
        await harness.model.loadMode()
        let session = try #require(harness.model.replySession)
        let form = try #require(harness.model.replyForm)
        session.drafts[form.id]?["message"] = ["Reply"]
        #expect(await harness.model.submit() == nil)
        #expect(!harness.model.didSubmit)
        #expect(session.drafts[form.id]?["message"] == ["Reply"])
        harness.model.selectMode(.comment)
        harness.model.comment?.message = "Still here"
        harness.record.cancels = true
        #expect(await harness.model.submit() == nil)
        #expect(harness.model.comment?.errorMessage == nil)
        #expect(harness.model.comment?.message == "Still here")
    }

    @Test func placementRequiresEvidenceAndOnlyWarnsForNovelOwnerReply() {
        let incomplete = ChapterCommentsPage(target: chapter, comments: [], isBoundaryClosed: false, nextView: 9)
        let closed = ChapterCommentsPage(target: chapter, comments: [], isBoundaryClosed: true)
        let confirmed = ChapterCommentsPage(target: chapter, comments: [], isBoundaryClosed: false, isThreadEndConfirmed: true)
        let unverified = ChapterCommentsPage(target: chapter, comments: [], isBoundaryClosed: false)
        #expect(ReaderChapterReplyPlacement.resolve(target: chapter, hasLaterChapter: true, state: .idle) == .outsideChapter)
        #expect(ReaderChapterReplyPlacement.resolve(target: chapter, hasLaterChapter: false, state: .loaded(chapter, closed)) == .outsideChapter)
        #expect(ReaderChapterReplyPlacement.resolve(target: chapter, hasLaterChapter: false, state: .loaded(chapter, incomplete)) == .unknown)
        #expect(ReaderChapterReplyPlacement.resolve(target: chapter, hasLaterChapter: false, state: .loaded(chapter, unverified)) == .unknown)
        #expect(ReaderChapterReplyPlacement.resolve(target: chapter, hasLaterChapter: false, state: .loaded(chapter, confirmed)) == .withinChapter)
        #expect(ReaderChapterReplyPlacement.outsideChapter.warning(isNovel: true, isChapterOwner: true, mode: .reply) != nil)
        #expect(ReaderChapterReplyPlacement.outsideChapter.warning(isNovel: false, isChapterOwner: true, mode: .reply) == nil)
        #expect(ReaderChapterReplyPlacement.outsideChapter.warning(isNovel: true, isChapterOwner: false, mode: .reply) != nil)
        for mode in [ReaderChapterCommentComposeMode.rating, .comment] {
            #expect(ReaderChapterReplyPlacement.outsideChapter.warning(isNovel: true, isChapterOwner: true, mode: mode) == nil)
        }
    }

    @Test func loginRefreshUpdatesHiddenTokensWithoutLosingReplyDraft() async throws {
        let harness = try makeHarness()
        await harness.model.load()
        harness.model.selectMode(.reply)
        await harness.model.loadMode()
        let session = try #require(harness.model.replySession)
        let form = try #require(harness.model.replyForm)
        session.drafts[form.id]?["message"] = ["[b]Keep this draft[/b]"]
        let refreshedForm = ForumForm(id: "new-postform", title: "Reply", actionURL: form.actionURL, kind: .thread,
            fields: [.init(id: "new-message", name: "message", label: "Reply", kind: .multiline, initialValues: ["New server quote"], isRequired: true)],
            hiddenValues: [.init(name: "formhash", value: "refreshed-token")], buttons: form.buttons)
        await harness.repository.setPage(ForumPageDocument(url: form.actionURL, title: "Reply", forms: [refreshedForm]))
        await harness.model.load(retry: true)
        #expect(session.drafts["new-postform"]?["new-message"] == ["[b]Keep this draft[/b]"])
        #expect(harness.model.replyForm?.hiddenValues.first?.value == "refreshed-token")
        #expect(harness.model.canSubmit)
    }

    private func makeHarness() throws -> (model: ReaderChapterCommentComposerModel, record: ComposerActionRecord, repository: ChapterReplyTestRepository) {
        let record = ComposerActionRecord()
        let target = try #require(ReaderChapterCommentComposeTarget.owner(chapter))
        let url = YamiboRoute.threadPostReply(tid: "123", pid: "456", page: 9).url
        let form = ForumForm(id: "postform", title: "Reply", actionURL: url, kind: .thread,
                             fields: [.init(id: "message", name: "message", label: "Reply", kind: .multiline, initialValues: ["[quote]Source[/quote]"], isRequired: true)],
                             buttons: [.init(id: "send", title: "Send")])
        let repository = ChapterReplyTestRepository(page: ForumPageDocument(url: url, title: "Reply", forms: [form]))
        let actions = ReaderChapterCommentComposeActions(loadContext: { tid, pid in
            if let error = record.contextError { throw error }
            if record.fails { throw YamiboError.notAuthenticated }
            return ForumPostActionContext(threadID: tid, post: .init(postID: pid, author: .init(uid: "42", name: "Author"), contentHTML: "", contentText: "Chapter"), page: record.page, formHash: "fresh")
        }, loadRateOptions: { _, _ in
            record.optionLoads += 1
            if let error = record.optionsError { throw error }
            return .init(availableScores: [1, 2], defaultReasons: ["Good"])
        }, rate: { context, _, _, _ in
            if let error = record.submissionError { throw error }
            if record.fails { throw YamiboError.notAuthenticated }
            record.contexts.append(context)
            return "评分成功"
        }, comment: { context, _ in
            if let error = record.submissionError { throw error }
            if record.cancels { throw CancellationError() }
            record.contexts.append(context)
            if record.suspends { await withCheckedContinuation { record.continuation = $0 } }
            return "点评成功"
        }, makeReplySession: { ForumPageSession(url: $0, repository: repository) })
        return (ReaderChapterCommentComposerModel(target: target, actions: actions), record, repository)
    }
}

@MainActor private final class ComposerActionRecord {
    var contexts: [ForumPostActionContext] = []
    var contextError: (any Error)?
    var optionsError: (any Error)?
    var submissionError: (any Error)?
    var optionLoads = 0
    var fails = false
    var cancels = false
    var page = 9
    var suspends = false
    var continuation: CheckedContinuation<Void, Never>?
}

private actor ChapterReplyTestRepository: ForumPageLoading {
    var page: ForumPageDocument
    private(set) var loads = 0
    private(set) var submissions = 0
    var message = "发表成功"
    var submissionError: (any Error)?
    init(page: ForumPageDocument) { self.page = page }
    func setPage(_ page: ForumPageDocument) { self.page = page }
    func setMessage(_ message: String) { self.message = message }
    func setSubmissionError(_ error: any Error) { submissionError = error }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { loads += 1; return .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        submissions += 1
        if let submissionError { throw submissionError }
        return .page(ForumPageDocument(url: page.url, title: "Result", message: message))
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        throw ForumPageError.unsupportedUpload
    }
}
