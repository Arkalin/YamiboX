import Foundation
import Observation
import YamiboXCore

enum ReaderChapterCommentComposeMode: String, CaseIterable, Identifiable {
    case rating, comment, reply

    var id: Self { self }
    var title: String {
        switch self {
        case .rating: L10n.string("forum.thread.rate")
        case .comment: L10n.string("forum.thread.comment")
        case .reply: L10n.string("forum.thread.reply")
        }
    }
}

struct ReaderChapterCommentComposeTarget: Identifiable, Equatable {
    let chapter: ReaderChapterCommentTarget
    let postID: String
    let authorName: String?
    let excerpt: String?
    let isChapterOwner: Bool

    var id: String { "\(chapter.threadID):\(postID)" }
    var initialMode: ReaderChapterCommentComposeMode { isChapterOwner ? .comment : .reply }

    static func owner(_ chapter: ReaderChapterCommentTarget) -> Self? {
        guard !chapter.ownerPostID.isEmpty else { return nil }
        return Self(chapter: chapter, postID: chapter.ownerPostID, authorName: nil, excerpt: chapter.title, isChapterOwner: true)
    }

    static func reply(_ comment: ChapterComment, chapter: ReaderChapterCommentTarget) -> Self? {
        guard comment.source == .reply, let postID = comment.postID, postID != chapter.ownerPostID else { return nil }
        return Self(chapter: chapter, postID: postID, authorName: comment.authorName, excerpt: comment.body, isChapterOwner: false)
    }
}

enum ReaderChapterReplyPlacement: Equatable {
    case outsideChapter, withinChapter, unknown

    static func resolve(target: ReaderChapterCommentTarget, hasLaterChapter: Bool, state: ReaderChapterCommentsState) -> Self {
        if hasLaterChapter { return .outsideChapter }
        guard case let .loaded(loadedTarget, page) = state, loadedTarget == target else { return .unknown }
        if page.isBoundaryClosed { return .outsideChapter }
        if page.nextView == nil, page.isThreadEndConfirmed == true { return .withinChapter }
        return .unknown
    }

    func warning(isNovel: Bool, isChapterOwner: Bool, mode: ReaderChapterCommentComposeMode) -> String? {
        guard isNovel, mode == .reply else { return nil }
        switch self {
        case .outsideChapter: return L10n.string("reader.comment_composer.reply_outside_chapter")
        case .withinChapter: return nil
        case .unknown: return L10n.string("reader.comment_composer.reply_placement_unknown")
        }
    }
}

@MainActor
struct ReaderChapterCommentComposeActions {
    var loadContext: (String, String) async throws -> ForumPostActionContext
    var loadRateOptions: (String, String) async throws -> ForumThreadRateOptionsPage
    var rate: (ForumPostActionContext, Int, String, Bool) async throws -> String
    var comment: (ForumPostActionContext, String) async throws -> String
    var makeReplySession: (URL) -> ForumPageSession

    init(dependencies: ForumDependencies, onSubmissionAccepted: @escaping (ForumSubmissionChange) -> Void) {
        loadContext = { tid, pid in
            guard await dependencies.sessionStore.load().isLoggedIn else { throw YamiboError.notAuthenticated }
            let repository = await dependencies.makeForumThreadReaderRepository()
            return try await repository.fetchPostActionContext(threadID: tid, postID: pid)
        }
        loadRateOptions = { tid, pid in
            let repository = await dependencies.makeForumThreadReaderRepository()
            return try await repository.fetchRateOptions(threadID: tid, postID: pid)
        }
        rate = { context, score, reason, notice in
            let repository = await dependencies.makeForumThreadReaderRepository()
            let result = try await repository.ratePost(threadID: context.threadID, postID: context.post.postID,
                                                 score: score, reason: reason, formHash: context.formHash, noticeAuthor: notice)
            onSubmissionAccepted(ForumSubmissionChange(postInteractionThreadID: context.threadID))
            return result
        }
        comment = { context, message in
            let repository = await dependencies.makeForumThreadReaderRepository()
            let result = try await repository.commentPost(threadID: context.threadID, postID: context.post.postID,
                                                    message: message, formHash: context.formHash, page: context.page)
            onSubmissionAccepted(ForumSubmissionChange(postInteractionThreadID: context.threadID))
            return result
        }
        makeReplySession = { ForumPageSession(url: $0, dependencies: dependencies, onSubmissionAccepted: onSubmissionAccepted) }
    }

    init(
        loadContext: @escaping (String, String) async throws -> ForumPostActionContext,
        loadRateOptions: @escaping (String, String) async throws -> ForumThreadRateOptionsPage,
        rate: @escaping (ForumPostActionContext, Int, String, Bool) async throws -> String,
        comment: @escaping (ForumPostActionContext, String) async throws -> String,
        makeReplySession: @escaping (URL) -> ForumPageSession
    ) {
        self.loadContext = loadContext
        self.loadRateOptions = loadRateOptions
        self.rate = rate
        self.comment = comment
        self.makeReplySession = makeReplySession
    }
}

@MainActor
@Observable
final class ReaderChapterCommentComposerModel {
    let target: ReaderChapterCommentComposeTarget
    private(set) var mode: ReaderChapterCommentComposeMode
    private(set) var context: ForumPostActionContext?
    private(set) var rating: ForumThreadRateSheetModel?
    private(set) var comment: ForumThreadCommentSheetModel?
    private(set) var replySession: ForumPageSession?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var didSubmit = false
    var isPreparingAttachment = false
    var feedback: TransientFeedback?

    @ObservationIgnored let editorRegistry = ForumEditorRegistry()
    @ObservationIgnored private let actions: ReaderChapterCommentComposeActions

    init(target: ReaderChapterCommentComposeTarget, actions: ReaderChapterCommentComposeActions) {
        self.target = target
        self.mode = target.initialMode
        self.actions = actions
    }

    var authorName: String {
        context?.post.author.name.nilIfBlank ?? target.authorName?.nilIfBlank
            ?? L10n.string(isLoading ? "common.loading" : "forum.thread.unknown_author")
    }

    var isBusy: Bool {
        isSubmitting || replySession?.isSubmitting == true || replySession?.isUploading == true || isPreparingAttachment
    }

    var hasEdits: Bool {
        guard !didSubmit else { return false }
        return !(comment?.message.isEmpty ?? true) || !(rating?.scoreText.isEmpty ?? true)
            || !(rating?.reason.isEmpty ?? true) || rating?.noticeAuthor == true || replySession?.hasEdits == true
    }

    var hasSubmissionFailure: Bool {
        switch mode {
        case .rating: rating?.options != nil && rating?.errorMessage != nil
        case .comment: comment?.errorMessage != nil
        case .reply: replyForm != nil && replySession?.errorMessage != nil
        }
    }

    var submissionRequiresAuthentication: Bool {
        switch mode {
        case .rating: rating?.errorDetails?.requiresAuthentication == true
        case .comment: comment?.errorDetails?.requiresAuthentication == true
        case .reply: replySession?.errorDetails?.requiresAuthentication == true
        }
    }

    var replyForm: ForumForm? { replySession?.page?.forms.first { $0.kind == .thread } }

    var replyButton: ForumFormButton? {
        replyForm?.buttons.first { !$0.values.contains { $0.name == "save" && $0.value == "1" } }
    }

    var canSubmit: Bool {
        guard context != nil, !isLoading, !isBusy, !didSubmit else { return false }
        switch mode {
        case .rating:
            guard let rating, let options = rating.options, !rating.isLoadingOptions,
                  let score = Int(rating.scoreText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return options.availableScores.isEmpty || options.availableScores.contains(score)
        case .comment:
            return comment?.canSubmit == true
        case .reply:
            guard let session = replySession, !session.isLoading, !session.submissionSucceeded,
                  let form = replyForm, let button = replyButton,
                  let field = form.fields.first(where: { $0.name == "message" }) else { return false }
            let values = session.drafts[form.id] ?? form.initialValues
            let message = values[field.id]?.first ?? ""
            return session.hasEdits && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (try? form.submissionValues(values: values, buttonID: button.id)) != nil
        }
    }

    func selectMode(_ newMode: ReaderChapterCommentComposeMode) {
        guard !isBusy, !didSubmit, mode != newMode else { return }
        editorRegistry.commitEditing()
        mode = newMode
        if context != nil { clearFailure() }
    }

    func load(retry: Bool = false) async {
        guard !isBusy, !isLoading, !didSubmit else { return }
        isLoading = true
        defer { isLoading = false }
        if retry { editorRegistry.commitEditing() }
        if context == nil || retry {
            do {
                let loaded = try await actions.loadContext(target.chapter.threadID, target.postID)
                try Task.checkCancellation()
                guard loaded.threadID == target.chapter.threadID, loaded.post.postID == target.postID,
                      loaded.page > 0, !loaded.formHash.isEmpty else { throw ReaderChapterCommentsUnavailableError() }
                context = loaded
                installModels()
                clearFailure()
            } catch {
                if !LoadDiagnosticError.isCancellation(error), !Task.isCancelled {
                    context = nil
                    feedback = .failure(error)
                }
                return
            }
        }
        if retry, let replySession, replySession.page != nil {
            await replySession.reloadComposerPreservingEdits()
        }
        await loadMode(retry: retry)
    }

    func loadMode(retry: Bool = false) async {
        guard context != nil, !isBusy, !didSubmit else { return }
        switch mode {
        case .rating:
            if let rating, !rating.isLoadingOptions, (rating.options == nil && rating.optionsFailure == nil) || retry {
                await rating.loadRateOptions()
            }
        case .comment: break
        case .reply:
            await replySession?.load()
        }
    }

    func submit() async -> TransientFeedback? {
        editorRegistry.commitEditing()
        guard canSubmit else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        let succeeded: Bool
        let message: String?
        switch mode {
        case .rating:
            succeeded = await rating?.submitRate() == true
            message = rating?.successMessage
        case .comment:
            succeeded = await comment?.submitComment() == true
            message = comment?.successMessage
        case .reply:
            guard let session = replySession, let form = replyForm, let button = replyButton else { return nil }
            editorRegistry.prepareSubmission(form: form, button: button, model: session)
            guard let submission = session.pendingSubmission else { return nil }
            await session.confirmSubmission(submission)
            succeeded = session.submissionSucceeded
            message = session.transientFeedback?.message
        }
        guard succeeded, !Task.isCancelled else { return nil }
        didSubmit = true
        return TransientFeedback(message: message ?? L10n.string("forum.native.submitted"))
    }

    func clearFailure() {
        feedback = nil
        rating?.clearError()
        comment?.clearError()
        replySession?.clearError()
    }

    private func requireContext() throws -> ForumPostActionContext {
        guard let context else { throw ReaderChapterCommentsUnavailableError() }
        return context
    }

    private func installModels() {
        if rating == nil {
            rating = ForumThreadRateSheetModel(postID: target.postID, loadOptions: { [actions, target] pid in
                try await actions.loadRateOptions(target.chapter.threadID, pid)
            }, submit: { [weak self, actions] _, score, reason, notice in
                guard let self else { throw CancellationError() }
                return try await actions.rate(self.requireContext(), score, reason, notice)
            })
        }
        if comment == nil {
            comment = ForumThreadCommentSheetModel(postID: target.postID) { [weak self, actions] _, message in
                guard let self else { throw CancellationError() }
                return try await actions.comment(self.requireContext(), message)
            }
        }
        if replySession == nil, let context {
            replySession = actions.makeReplySession(context.replyURL)
        }
    }
}
