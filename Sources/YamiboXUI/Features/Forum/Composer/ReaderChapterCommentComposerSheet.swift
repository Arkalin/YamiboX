import SwiftUI
import YamiboXCore

#if os(iOS)
struct ReaderChapterCommentComposerSheet<Destination: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Reserve editing space above the keyboard without shrinking accessibility text.
                    if dynamicTypeSize.isAccessibilitySize, geometry.size.height < 600 {
                        ScrollView { header }
                            .frame(maxHeight: geometry.size.height * 0.45)
                    } else {
                        header
                    }
                    Divider()
                    ReaderChapterCommentComposerFields(model: model, onURLTap: openURL)
                }
            }
            .modifier(ForumComposerSurface())
            .navigationTitle(L10n.string("reader.comment_composer.title"))
            .toolbar {
                ForumComposerToolbar(identifier: "chapter-comment", isBusy: model.isBusy,
                                     isSubmitting: model.isSubmitting, canSubmit: model.canSubmit, close: close) {
                    commitEditing()
                    submissionTask = Task {
                        if let feedback = await model.submit() {
                            onSubmitted(feedback)
                            dismiss()
                        }
                    }
                }
            }
        }
        .modifier(ForumComposerSheetPresentation())
        .interactiveDismissDisabled(model.hasEdits || model.isBusy)
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

    private var header: some View {
        ReaderChapterCommentComposerHeader(
            target: model.target, author: model.authorName,
            mode: Binding(get: { model.mode }, set: { commitEditing(); model.selectMode($0) }),
            warning: replyPlacement.warning(isNovel: isNovel, isChapterOwner: model.target.isChapterOwner, mode: model.mode),
            disabled: model.isBusy || model.didSubmit
        )
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
                    ForumComposerFailure(message: failure.message, details: failure.details, retry: { await model.load(retry: true) }, onURLTap: onURLTap)
                } else {
                    ContentLoadingView(layout: .fills)
                }
            } else {
                switch model.mode {
                case .rating:
                    if let rating = model.rating {
                        ForumPostRatingFields(model: rating, disabled: model.isBusy, onURLTap: onURLTap)
                    }
                case .comment:
                    if let comment = model.comment {
                        ForumPostCommentFields(model: comment, disabled: model.isBusy)
                    }
                case .reply:
                    if let session = model.replySession {
                        ForumPostReplyFields(session: session, form: model.replyForm, editorRegistry: model.editorRegistry,
                                             isEmbedded: true, onAttachmentActivityChanged: { model.isPreparingAttachment = $0 },
                                             onURLTap: onURLTap)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(model.isLoading || model.didSubmit)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasSubmissionFailure {
                HStack {
                    if model.submissionRequiresAuthentication {
                        Button(L10n.string("mine.web_login")) { onURLTap(YamiboRoute.login.url) }
                            .accessibilityIdentifier("chapter-comment-web-login")
                    }
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
