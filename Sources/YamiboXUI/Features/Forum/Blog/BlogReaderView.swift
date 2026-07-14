import SwiftUI
import YamiboXCore

struct BlogReaderView: View {
    @State private var model: BlogReaderViewModel

    let onUserTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    init(
        model: BlogReaderViewModel,
        onUserTap: @escaping (String, String?) -> Void,
        onWebTap: @escaping (URL) -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onUserTap = onUserTap
        self.onWebTap = onWebTap
    }

    var body: some View {
        BlogReaderBodyView(
            page: model.page,
            currentPage: model.currentPage,
            pageNavigation: model.pageNavigation,
            isLoading: model.isLoading,
            isSubmittingComment: model.isSubmittingComment,
            canEditComment: model.canEditComment,
            canSubmitComment: model.canSubmitComment,
            commentText: model.commentText,
            commentPlaceholder: model.commentPlaceholder,
            errorMessage: model.errorMessage,
            refresh: refresh,
            retry: retry,
            goToPage: goToPage,
            updateCommentText: updateCommentText,
            submitComment: submitComment,
            onUserTap: onUserTap,
            onWebTap: onWebTap
        )
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .task {
            await model.load()
        }
        .transientMessage(model.commentResultMessage) {
            model.clearCommentResult()
        }
        .alert(
            L10n.string("blog_reader.comment_failed_title"),
            isPresented: Binding(
                get: { model.page != nil && model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.string("common.ok")) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func refresh() async {
        await model.refresh()
    }

    private func retry() {
        Task {
            await model.refresh()
        }
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }

    private func updateCommentText(_ text: String) {
        model.commentText = text
    }

    private func submitComment() {
        Task {
            await model.submitComment()
        }
    }
}

private struct BlogReaderBodyView: View {
    let page: BlogReaderPage?
    let currentPage: Int
    let pageNavigation: ForumPageNavigation?
    let isLoading: Bool
    let isSubmittingComment: Bool
    let canEditComment: Bool
    let canSubmitComment: Bool
    let commentText: String
    let commentPlaceholder: String
    let errorMessage: String?
    let refresh: () async -> Void
    let retry: () -> Void
    let goToPage: (Int) -> Void
    let updateCommentText: (String) -> Void
    let submitComment: () -> Void
    let onUserTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let page {
                    BlogReaderRootCard(page: page, onUserTap: onUserTap, onWebTap: onWebTap)
                    BlogReaderCommentSection(
                        comments: page.comments,
                        currentPage: currentPage,
                        pageNavigation: pageNavigation,
                        isSubmittingComment: isSubmittingComment,
                        canEditComment: canEditComment,
                        canSubmitComment: canSubmitComment,
                        commentText: commentText,
                        commentPlaceholder: commentPlaceholder,
                        goToPage: goToPage,
                        updateCommentText: updateCommentText,
                        submitComment: submitComment,
                        onUserTap: onUserTap,
                        onWebTap: onWebTap
                    )
                } else if isLoading {
                    ForumContentLoadingView()
                } else if let errorMessage {
                    LoadFailureView(message: errorMessage, retry: retry)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshable {
            await refresh()
        }
        .topRefreshIndicator(isVisible: isLoading && page != nil)
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
    }
}

private struct BlogReaderRootCard: View {
    let page: BlogReaderPage
    let onUserTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ForumColors.textDark)
                .fixedSize(horizontal: false, vertical: true)

            BlogReaderAuthorRow(user: page.author, postedAtText: page.postedAtText, onUserTap: onUserTap)

            BlogReaderStatRow(viewCount: page.viewCount, replyCount: page.replyCount)

            Text(page.contentText)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(ForumColors.textDark)
                .textSelection(.enabled)

            BlogReaderActionRow(page: page, onWebTap: onWebTap)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }
}

private struct BlogReaderAuthorRow: View {
    let user: BlogReaderUser
    let postedAtText: String?
    let onUserTap: (String, String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForumAvatarView(url: user.avatarURL, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                if let uid = user.uid {
                    Button(user.name) {
                        onUserTap(uid, user.name)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.brownPrimary)
                } else {
                    Text(user.name)
                        .font(.subheadline.weight(.semibold))
                }
                if let postedAtText {
                    Text(postedAtText)
                        .font(.caption)
                        .foregroundStyle(ForumColors.brownLight)
                }
            }
            Spacer()
        }
    }
}

private struct BlogReaderStatRow: View {
    let viewCount: Int?
    let replyCount: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let viewCount {
                Label(String(viewCount), systemImage: "eye")
            }
            if let replyCount {
                Label(String(replyCount), systemImage: "bubble.right")
            }
        }
        .font(.caption)
        .foregroundStyle(ForumColors.secondaryText)
    }
}

private struct BlogReaderActionRow: View {
    let page: BlogReaderPage
    let onWebTap: (URL) -> Void

    var body: some View {
        ViewThatFits {
            HStack(spacing: 8) {
                actionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(ForumColors.brownEmphasis)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let collectURL = page.collectURL {
            Button {
                onWebTap(collectURL)
            } label: {
                Label(L10n.string("blog_reader.collect"), systemImage: "star")
            }
        }
        if let shareURL = page.shareURL {
            Button {
                onWebTap(shareURL)
            } label: {
                Label(L10n.string("blog_reader.share"), systemImage: "square.and.arrow.up")
            }
        }
        if let inviteURL = page.inviteURL {
            Button {
                onWebTap(inviteURL)
            } label: {
                Label(L10n.string("blog_reader.invite"), systemImage: "person.badge.plus")
            }
        }
    }
}

private struct BlogReaderCommentSection: View {
    let comments: [BlogReaderComment]
    let currentPage: Int
    let pageNavigation: ForumPageNavigation?
    let isSubmittingComment: Bool
    let canEditComment: Bool
    let canSubmitComment: Bool
    let commentText: String
    let commentPlaceholder: String
    let goToPage: (Int) -> Void
    let updateCommentText: (String) -> Void
    let submitComment: () -> Void
    let onUserTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("blog_reader.comments"))
                .font(.headline)
                .foregroundStyle(ForumColors.brownPrimary)
            if comments.isEmpty {
                ContentUnavailableView(L10n.string("blog_reader.empty_comments"), systemImage: "bubble.left")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(comments) { comment in
                    BlogReaderCommentRow(comment: comment, onUserTap: onUserTap, onWebTap: onWebTap)
                }
            }
            ForumPageNavigationBar(navigation: pageNavigation, currentPage: currentPage, goToPage: goToPage)
            BlogReaderCommentEditor(
                text: commentText,
                placeholder: commentPlaceholder,
                canEdit: canEditComment,
                canSubmit: canSubmitComment,
                isSubmitting: isSubmittingComment,
                updateText: updateCommentText,
                submit: submitComment
            )
        }
    }
}

private struct BlogReaderCommentEditor: View {
    let text: String
    let placeholder: String
    let canEdit: Bool
    let canSubmit: Bool
    let isSubmitting: Bool
    let updateText: (String) -> Void
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("blog_reader.write_comment"))
                .font(.headline)
                .foregroundStyle(ForumColors.brownPrimary)

            TextField(
                placeholder,
                text: Binding(
                    get: { text },
                    set: { newValue in
                        updateText(newValue)
                    }
                ),
                axis: .vertical
            )
            .lineLimit(3 ... 6)
            .textFieldStyle(.roundedBorder)
            .disabled(!canEdit)

            Button {
                submit()
            } label: {
                Label(
                    isSubmitting ? L10n.string("blog_reader.comment_submitting") : L10n.string("blog_reader.comment_submit"),
                    systemImage: "paperplane"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ForumColors.brownDeep)
            .disabled(!canSubmit)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }
}

private struct BlogReaderCommentRow: View {
    let comment: BlogReaderComment
    let onUserTap: (String, String?) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForumAvatarView(url: comment.author.avatarURL, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    if let uid = comment.author.uid {
                        Button(comment.author.name) {
                            onUserTap(uid, comment.author.name)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ForumColors.brownPrimary)
                    } else {
                        Text(comment.author.name)
                    }
                    if let postedAtText = comment.postedAtText {
                        Text(postedAtText)
                            .font(.caption)
                            .foregroundStyle(ForumColors.brownLight)
                    }
                }
                Spacer()
                if let replyURL = comment.replyURL {
                    Button {
                        onWebTap(replyURL)
                    } label: {
                        Text(L10n.string("blog_reader.reply"))
                            .expandedHitTarget()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                }
            }

            Text(comment.contentText)
                .font(.subheadline)
                .foregroundStyle(ForumColors.textDark)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }
}



