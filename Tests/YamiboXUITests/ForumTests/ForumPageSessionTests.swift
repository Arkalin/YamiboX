import Foundation
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite struct ForumPageSessionTests {
    private let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16")!
    private var form: ForumForm {
        ForumForm(id: "post", title: "Post", actionURL: url, kind: .thread,
                        fields: [.init(id: "subject", name: "subject", label: "Title", initialValues: ["Title"], isRequired: true),
                                 .init(id: "message", name: "message", label: "Body", kind: .multiline, initialValues: ["Body"], isRequired: true)],
                        hiddenValues: [.init(name: "formhash", value: "fixture-token")], buttons: [.init(id: "post", title: "Post")])
    }

    @Test func preparingAndCancellingSubmissionNeverWrites() async {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.prepareSubmission(form: form, button: form.buttons[0])
        #expect(model.pendingSubmission != nil)
        #expect(await repo.submissions == 0)
        model.pendingSubmission = nil
        await model.confirmSubmission()
        #expect(await repo.submissions == 0)
    }

    @Test func loadExposesWebFallbackWithoutCreatingAnEmptyDocument() async {
        let repo = PageSessionRepository(page: .init(url: url, title: ""), loadResult: .webFallback(url))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        #expect(model.page == nil)
        #expect(model.navigationResult == .webFallback(url))
        #expect(!model.isLoading)
        #expect(await repo.loads == 1)
    }

    @Test func getResultRoutesWithoutClaimingSubmissionSuccess() async {
        let getForm = ForumForm(id: "search", title: "Search", actionURL: url, method: "GET", buttons: [.init(id: "search", title: "Search")])
        let target = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let repo = PageSessionRepository(page: .init(url: url, title: "Search", forms: [getForm]), submissionResult: .nativeRedirect(target))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.prepareSubmission(form: getForm, button: getForm.buttons[0])
        await model.confirmSubmission()
        #expect(model.navigationResult == .nativeRedirect(target))
        #expect(!model.submissionSucceeded)
        #expect(await repo.submissions == 1)
    }

    @Test func unexpectedPostNavigationNeverDiscardsDraftOrReplays() async {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]), submissionResult: .webFallback(url))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["message"] = ["Keep this draft"]
        model.prepareSubmission(form: form, button: form.buttons[0])
        await model.confirmSubmission()
        await model.confirmSubmission()
        #expect(model.navigationResult == nil)
        #expect(!model.submissionSucceeded)
        #expect(model.drafts[form.id]?["message"] == ["Keep this draft"])
        #expect(model.errorMessage != nil)
        #expect(await repo.submissions == 1)
    }

    @Test(arguments: ["发表成功", "等待审核", "抱歉，没有权限", "Unknown response"])
    func onlyConfirmedSuccessPublishesOneContentChange(message: String) async throws {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]),
                                         result: .init(url: url, title: "", message: message))
        var changes: [ForumSubmissionChange] = []
        let model = ForumPageSession(url: url, repository: repo, onSubmissionAccepted: { changes.append($0) })
        await model.load()
        model.prepareSubmission(form: form, button: form.buttons[0])
        let snapshot = try #require(model.pendingSubmission)
        #expect(changes.isEmpty)
        await model.confirmSubmission(snapshot)
        await model.confirmSubmission(snapshot)
        #expect(changes.count == (model.submissionSucceeded ? 1 : 0))
        #expect(await repo.submissions == 1)
    }

    @Test func failedSubmissionRetainsDraftAndDoesNotRetryAutomatically() async {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["message"] = ["Unsaved draft"]
        model.prepareSubmission(form: form, button: form.buttons[0])
        await model.confirmSubmission()
        #expect(!model.submissionSucceeded)
        #expect(model.errorMessage != nil)
        #expect(model.transientFeedback?.message == model.errorMessage)
        #expect(model.transientFeedback?.details != nil)
        #expect(model.drafts[form.id]?["message"] == ["Unsaved draft"])
        #expect(await repo.submissions == 1)
        await model.confirmSubmission()
        #expect(await repo.submissions == 1)
    }

    @Test func confirmedSnapshotSurvivesDialogDismissalBeforeTaskRuns() async throws {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]), result: .init(url: url, title: "", message: "发表成功"))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["message"] = ["Confirmed reply"]
        model.prepareSubmission(form: form, button: form.buttons[0])
        let submission = try #require(model.pendingSubmission)
        let task = Task { await model.confirmSubmission(submission) }
        // SwiftUI dismisses the dialog on the same actor before the task starts.
        model.pendingSubmission = nil
        model.drafts[form.id]?["message"] = ["Later draft"]
        await task.value

        #expect(await repo.submissions == 1)
        #expect(await repo.submittedValues?["message"] == ["Confirmed reply"])
        #expect(model.submissionSucceeded)
        #expect(!model.isSubmitting)
        #expect(model.transientFeedback?.message == "发表成功")
        #expect(model.transientFeedback?.details == nil)
        await model.confirmSubmission(submission)
        #expect(await repo.submissions == 1)
    }

    @Test func failedConfirmationCannotReplayButNewConfirmationCanRetry() async throws {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.prepareSubmission(form: form, button: form.buttons[0])
        let first = try #require(model.pendingSubmission)
        model.pendingSubmission = nil
        await model.confirmSubmission(first)
        await model.confirmSubmission(first)
        #expect(await repo.submissions == 1)
        #expect(model.errorMessage != nil)
        #expect(model.drafts[form.id]?["message"] == ["Body"])

        model.prepareSubmission(form: form, button: form.buttons[0])
        let retry = try #require(model.pendingSubmission)
        #expect(retry.id != first.id)
        model.pendingSubmission = nil
        await model.confirmSubmission(retry)
        #expect(await repo.submissions == 2)
    }

    @Test func confirmedSuccessfulSubmissionPreventsDuplicateSubmit() async {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]), result: .init(url: url, title: "", message: "发表成功"))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.prepareSubmission(form: form, button: form.buttons[0])
        await model.confirmSubmission()
        #expect(model.submissionSucceeded)
        model.prepareSubmission(form: form, button: form.buttons[0])
        #expect(model.pendingSubmission == nil)
        #expect(await repo.submissions == 1)
    }

    @Test func editedDraftRequiresDiscardBeforeRefresh() async {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["subject"] = ["Edited"]
        await model.refresh()
        #expect(model.showsDiscardConfirmation)
        #expect(await repo.loads == 1)
        await model.refresh(discardingEdits: true)
        #expect(await repo.loads == 2)
        #expect(!model.hasEdits)
    }

    @Test func mutationLoadRequiresFreshConfirmationAfterRefresh() async {
        let actionURL = URL(string: "https://bbs.yamibo.com/home.php?op=delete&formhash=fixture")!
        let repo = PageSessionRepository(page: .init(url: actionURL, title: "Action"))
        let model = ForumPageSession(url: actionURL, repository: repo)
        await model.load()
        #expect(await repo.loads == 0)
        await model.load(confirmedAction: true)
        #expect(await repo.loads == 1)
        await model.refresh()
        #expect(model.requiresLoadConfirmation)
        #expect(await repo.loads == 1)
    }

    @Test func plainBlogBodyIsEscapedOnlyAtSubmissionBoundary() {
        #expect(ForumPageSession.htmlFromPlainText("<script>&\nnext") == "&lt;script&gt;&amp;<br>next")
    }

    @Test func repeatedServerRejectionProducesNewToastAndKeepsDraft() async throws {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]),
                                             result: .init(url: url, title: "Error", message: "抱歉，没有权限"))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["message"] = ["Unsaved draft"]
        model.prepareSubmission(form: form, button: form.buttons[0])
        await model.confirmSubmission()
        let first = try #require(model.transientFeedback)
        #expect(!model.submissionSucceeded)
        #expect(first.message == "抱歉，没有权限")
        #expect(first.details != nil)
        model.transientFeedback = nil
        #expect(model.hasEdits)
        #expect(model.drafts[form.id]?["message"] == ["Unsaved draft"])

        model.prepareSubmission(form: form, button: form.buttons[0])
        await model.confirmSubmission()
        let retry = try #require(model.transientFeedback)
        #expect(retry.id != first.id)
        #expect(retry.message == first.message)
        #expect(!model.submissionSucceeded)
        #expect(await repo.submissions == 2)
    }

    @Test func validationFailureShowsToastWithoutSending() async throws {
        let repo = PageSessionRepository(page: .init(url: url, title: "Post", forms: [form]))
        let model = ForumPageSession(url: url, repository: repo)
        await model.load()
        model.drafts[form.id]?["message"] = [""]
        model.prepareSubmission(form: form, button: form.buttons[0])
        #expect(model.pendingSubmission == nil)
        #expect(model.transientFeedback?.message == model.errorMessage)
        #expect(model.transientFeedback?.details != nil)
        #expect(!model.submissionSucceeded)
        #expect(await repo.submissions == 0)
        model.clearError()
        #expect(model.transientFeedback == nil)
    }
}

private actor PageSessionRepository: ForumPageLoading {
    let page: ForumPageDocument
    let result: ForumPageDocument?
    let loadResult: ForumPageLoadResult?
    let submissionResult: ForumPageLoadResult?
    private(set) var loads = 0
    private(set) var submissions = 0
    private(set) var submittedValues: [String: [String]]?
    init(page: ForumPageDocument, result: ForumPageDocument? = nil, loadResult: ForumPageLoadResult? = nil, submissionResult: ForumPageLoadResult? = nil) {
        self.page = page
        self.result = result
        self.loadResult = loadResult
        self.submissionResult = submissionResult
    }
    func fetchPage(url: URL, confirmedAction: Bool) -> ForumPageLoadResult { loads += 1; return loadResult ?? .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) throws -> ForumPageLoadResult {
        submissions += 1
        submittedValues = values
        if let submissionResult { return submissionResult }
        if let result { return .page(result) }
        throw URLError(.timedOut)
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) throws -> ForumUploadedAttachment {
        throw ForumPageError.unsupportedUpload
    }
}
