import SwiftUI
import YamiboXCore

struct ForumPostRatingFields: View {
    @Bindable var model: ForumThreadRateSheetModel
    let disabled: Bool
    var onURLTap: ((URL) -> Void)?

    var body: some View {
        Group {
            if let failure = model.optionsFailure {
                ForumComposerFailure(
                    title: L10n.string("forum.thread.rate_unavailable"), systemImage: "star.slash",
                    message: failure.message, details: failure.details, showsRetry: model.canRetryOptions,
                    retry: model.loadRateOptions, onURLTap: onURLTap
                )
            } else {
                ForumPostRatingForm(model: model, disabled: disabled)
            }
        }
        .failureToast(message: model.optionsFailure == nil ? model.errorMessage : nil, details: model.errorDetails,
                      eventID: model.errorEventID, clear: model.clearError)
    }
}

struct ForumPostReplyFields: View {
    let session: ForumPageSession
    let form: ForumForm?
    let editorRegistry: ForumEditorRegistry
    var isEmbedded = false
    var onSubmissionSucceeded: ((TransientFeedback) -> Void)?
    var onAttachmentActivityChanged: ((Bool) -> Void)?
    var onURLTap: ((URL) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let document = session.page, let form {
                ForumFormPageView(model: session, document: document, composerForm: form,
                                  editorRegistry: editorRegistry, onSubmissionSucceeded: onSubmissionSucceeded, isEmbedded: isEmbedded,
                                  onAttachmentActivityChanged: onAttachmentActivityChanged, onURLTap: { onURLTap?($0) })
            } else if session.isLoading || session.page == nil && session.errorMessage == nil {
                ContentLoadingView(layout: .fills)
            } else {
                ForumComposerFailure(
                    message: session.errorMessage ?? session.page?.message ?? L10n.string("reader.comment_composer.reply_unavailable"),
                    details: session.errorDetails,
                    retry: {
                        if session.page != nil { await session.refresh() }
                        else { await session.load() }
                    }, onURLTap: onURLTap
                )
            }
        }
        .transientMessage(isEmbedded ? session.transientFeedback : nil) { session.transientFeedback = nil }
    }
}

struct ForumComposerFailure: View {
    var title = L10n.string("common.load_failed")
    var systemImage = "exclamationmark.triangle"
    let message: String
    let details: LoadFailureDetails?
    var showsRetry = true
    let retry: () async -> Void
    var onURLTap: ((URL) -> Void)?

    var body: some View {
        VStack(spacing: ForumComposerStyle.contentInset) {
            LoadFailureView(title: title, systemImage: systemImage, message: message, details: details,
                            prominentRetry: true, showsRetry: showsRetry) { Task { await retry() } }
            if details?.requiresAuthentication == true, let onURLTap {
                Button(L10n.string("mine.web_login")) { onURLTap(YamiboRoute.login.url) }
                    .frame(minHeight: ForumComposerStyle.controlSize)
                    .accessibilityIdentifier("chapter-comment-web-login")
            }
        }
        .padding(ForumComposerStyle.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
