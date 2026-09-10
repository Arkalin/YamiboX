import SwiftUI
import YamiboXCore

#if os(iOS)
struct ReaderChapterCommentComposerSheet<Destination: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var model: ReaderChapterCommentComposerModel
    @State private var showsDiscardConfirmation = false
    @State private var destinationItem: ForumThreadOverlayItem?
    @State private var submissionTask: Task<Void, Never>?
    let replyPlacement: ReaderChapterReplyPlacement
    let isNovel: Bool
    let onSubmitted: (TransientFeedback) -> Void
    let destination: (URL) -> Destination

    init(
        model: ReaderChapterCommentComposerModel,
        replyPlacement: ReaderChapterReplyPlacement,
        isNovel: Bool,
        onSubmitted: @escaping (TransientFeedback) -> Void,
        @ViewBuilder destination: @escaping (URL) -> Destination
    ) {
        _model = State(wrappedValue: model)
        self.replyPlacement = replyPlacement
        self.isNovel = isNovel
        self.onSubmitted = onSubmitted
        self.destination = destination
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ReaderChapterCommentComposerHeader(
                    target: model.target,
                    author: model.authorName,
                    mode: Binding(get: { model.mode }, set: { commitEditing(); model.selectMode($0) }),
                    warning: replyPlacement.warning(isNovel: isNovel, isChapterOwner: model.target.isChapterOwner, mode: model.mode),
                    disabled: model.isBusy || model.didSubmit
                )
                Divider()
                ReaderChapterCommentComposerFields(model: model, onURLTap: openURL)
            }
            .background(Color(.systemBackground))
            .navigationTitle(L10n.string("reader.comment_composer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L10n.string("common.cancel"))
                    .accessibilityIdentifier("chapter-comment-close")
                    .disabled(model.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commitEditing()
                        submissionTask = Task {
                            if let feedback = await model.submit() {
                                onSubmitted(feedback)
                                dismiss()
                            }
                        }
                    } label: {
                        ZStack {
                            Image(systemName: "paperplane.fill").opacity(model.isSubmitting ? 0 : 1)
                            if model.isSubmitting { ProgressView() }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L10n.string("forum.thread.publish"))
                    .accessibilityIdentifier("chapter-comment-send")
                    .disabled(!model.canSubmit)
                }
            }
        }
        .tint(theme.controlAccent)
        .interactiveDismissDisabled(model.hasEdits || model.isBusy)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .confirmationDialog(L10n.string("forum.native.discard_title"), isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button(L10n.string("forum.native.discard_leave"), role: .destructive) { dismiss() }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        }
        .fullScreenCover(item: $destinationItem, onDismiss: {
            Task { await model.load(retry: true) }
        }) { item in
            destination(item.url)
        }
        .task { await model.load() }
        .task(id: model.mode) { await model.loadMode() }
        .onDisappear { submissionTask?.cancel() }
    }

    private func commitEditing() {
        model.editorRegistry.commitEditing()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func close() {
        guard !model.isBusy else { return }
        commitEditing()
        if model.hasEdits { showsDiscardConfirmation = true }
        else { dismiss() }
    }

    private func openURL(_ url: URL) {
        guard !model.isBusy else { return }
        commitEditing()
        destinationItem = ForumThreadOverlayItem(url: url, title: nil)
    }
}

private struct ReaderChapterCommentComposerHeader: View {
    let target: ReaderChapterCommentComposeTarget
    let author: String
    @Binding var mode: ReaderChapterCommentComposeMode
    let warning: String?
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.string(target.isChapterOwner ? "reader.comment_composer.chapter_author" : "reader.comment_composer.target"))
                        .foregroundStyle(.secondary)
                    Text(author)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chapter-comment-target")
                if let excerpt = target.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Picker(L10n.string("reader.comment_composer.mode"), selection: $mode) {
                ForEach(ReaderChapterCommentComposeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(disabled)
            .accessibilityIdentifier("chapter-comment-mode")
            if let warning {
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("chapter-comment-placement-warning")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ReaderChapterCommentComposerFields: View {
    let model: ReaderChapterCommentComposerModel
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.context == nil {
                if let failure = model.feedback {
                    ReaderChapterCommentComposerFailure(message: failure.message, details: failure.details, retry: { await model.load(retry: true) }, onURLTap: onURLTap)
                } else {
                    ContentLoadingView(layout: .fillsPage)
                }
            } else {
                switch model.mode {
                case .rating:
                    if let rating = model.rating {
                        ReaderChapterCommentRatingFields(model: rating, disabled: model.isBusy, onURLTap: onURLTap)
                    }
                case .comment:
                    if let comment = model.comment {
                        ReaderChapterCommentTextFields(model: comment, disabled: model.isBusy)
                    }
                case .reply:
                    if let session = model.replySession {
                        ReaderChapterCommentReplyFields(model: model, session: session, onURLTap: onURLTap)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(model.isLoading || model.didSubmit)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasSubmissionFailure {
                HStack {
                    Button(L10n.string("mine.web_login")) { onURLTap(YamiboRoute.login.url) }
                    Spacer()
                    Button {
                        Task { await model.load(retry: true) }
                    } label: {
                        Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                .background(.regularMaterial)
                .disabled(model.isLoading || model.isBusy)
            }
        }
    }
}

private struct ReaderChapterCommentRatingFields: View {
    @Bindable var model: ForumThreadRateSheetModel
    let disabled: Bool
    let onURLTap: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L10n.string("forum.thread.rate_score"))
                    Spacer()
                    TextField(L10n.string("forum.thread.rate_score"), text: $model.scoreText)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60, maxWidth: 100, minHeight: 44)
                        .accessibilityIdentifier("chapter-comment-score")
                    if let scores = model.options?.availableScores, !scores.isEmpty {
                        Menu {
                            ForEach(scores, id: \.self) { score in
                                Button(String(score)) { model.scoreText = String(score) }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(L10n.string("forum.thread.rate_score_options"))
                    }
                }
                Divider()
                TextField(L10n.string("forum.thread.rate_reason"), text: $model.reason, axis: .vertical)
                    .lineLimit(4 ... 8)
                    .accessibilityIdentifier("chapter-comment-reason")
                if let reasons = model.options?.defaultReasons, !reasons.isEmpty {
                    Menu {
                        ForEach(reasons, id: \.self) { reason in
                            Button(reason) { model.reason = reason }
                        }
                    } label: {
                        Label(L10n.string("forum.thread.rate_reason_options"), systemImage: "text.badge.plus")
                            .frame(minHeight: 44)
                    }
                }
                Divider()
                Toggle(L10n.string("forum.thread.rate_notice_author"), isOn: $model.noticeAuthor)
            }
            .padding(16)
            .disabled(disabled || model.isLoadingOptions)
            if model.isLoadingOptions { ProgressView().padding() }
            if model.options == nil, let message = model.errorMessage {
                ReaderChapterCommentComposerFailure(message: message, details: model.errorDetails, retry: model.loadRateOptions, onURLTap: onURLTap)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .failureToast(message: model.options == nil ? nil : model.errorMessage, details: model.errorDetails,
                      eventID: model.errorEventID, clear: model.clearError)
    }
}

private struct ReaderChapterCommentTextFields: View {
    @Bindable var model: ForumThreadCommentSheetModel
    let disabled: Bool

    var body: some View {
        TextEditor(text: $model.message)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if model.message.isEmpty {
                    Text(L10n.string("forum.thread.comment_placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .disabled(disabled)
            .accessibilityLabel(L10n.string("forum.thread.comment"))
            .accessibilityIdentifier("chapter-comment-text")
            .failureToast(message: model.errorMessage, details: model.errorDetails,
                          eventID: model.errorEventID, clear: model.clearError)
    }
}

private struct ReaderChapterCommentReplyFields: View {
    let model: ReaderChapterCommentComposerModel
    let session: ForumPageSession
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let document = session.page, let form = model.replyForm {
                ForumFormPageView(model: session, document: document, composerForm: form,
                                  editorRegistry: model.editorRegistry, isEmbedded: true,
                                  onAttachmentActivityChanged: { model.isPreparingAttachment = $0 }, onURLTap: onURLTap)
            } else if session.isLoading || session.page == nil && session.errorMessage == nil {
                ContentLoadingView(layout: .fillsPage)
            } else {
                ReaderChapterCommentComposerFailure(
                    message: session.errorMessage ?? session.page?.message ?? L10n.string("reader.comment_composer.reply_unavailable"),
                    details: session.errorDetails,
                    retry: {
                        if session.page != nil { await session.refresh() }
                        else { await session.load() }
                    }, onURLTap: onURLTap
                )
            }
        }
        .transientMessage(session.transientFeedback) { session.transientFeedback = nil }
    }
}

private struct ReaderChapterCommentComposerFailure: View {
    let message: String
    let details: LoadFailureDetails?
    let retry: () async -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(spacing: 16) {
            LoadFailureView(message: message, details: details, prominentRetry: true) { Task { await retry() } }
            Button(L10n.string("mine.web_login")) { onURLTap(YamiboRoute.login.url) }
                .frame(minHeight: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReaderChapterCommentComposerDestination: View {
    @Environment(\.dismiss) private var dismiss
    @State private var navigator: ForumDestinationNavigator
    let url: URL

    init(url: URL, dependencies: ForumDependencies, appModel: YamiboAppModel, discussionWorkTIDs: Set<String>) {
        self.url = url
        _navigator = State(wrappedValue: ForumDestinationNavigator(dependencies: dependencies, appModel: appModel,
                                                                   mode: .readerOverlay, discussionWorkTIDs: discussionWorkTIDs))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator) {
            ForumDestinationScreen(destination: .web(url), navigator: navigator)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.string("common.done"))
                    }
                }
        }
    }
}
#endif
