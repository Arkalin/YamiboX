import SwiftUI
import YamiboXCore

struct ForumThreadPostCard: View {
    @State private var isShowingRateSheet = false
    @State private var isShowingCommentSheet = false

    let post: ForumThreadPost
    let isTarget: Bool
    let threadTitle: String?
    let totalViews: Int?
    let totalReplies: Int?
    let refererURL: URL
    let threadID: String
    let currentPage: Int
    let onUserTap: (String, String?) -> Void
    let onImageTap: (String, URL, String?, URL) -> Void
    let onShowRatingResults: (String) -> Void
    let onShowPollVoters: (String?) -> Void
    let onVotePoll: ([String]) async throws -> String
    let onLoadRateOptions: (String) async throws -> ForumThreadRateOptionsPage
    let onRatePost: (String, Int, String, Bool) async throws -> String
    let onCommentPost: (String, String) async throws -> String
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let threadTitle {
                ForumThreadPostTitleHeader(
                    title: threadTitle,
                    totalViews: totalViews,
                    totalReplies: totalReplies
                )
            }

            ForumThreadPostHeader(
                post: post,
                onUserTap: onUserTap,
                onURLTap: onURLTap
            )

            ForumThreadContentBlocksView(
                blocks: post.contentBlocks,
                fallbackText: post.contentText,
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )

            if let lastEditedText = post.lastEditedText {
                ForumThreadPostEditedTextView(text: lastEditedText)
            }

            if let poll = post.poll {
                ForumThreadPollView(
                    poll: poll,
                    onVote: onVotePoll,
                    onShowVoters: poll.status == .voted ? {
                        onShowPollVoters(nil)
                    } : nil
                )
            }

            if let ratingBlock = post.ratingBlock {
                ForumThreadRatingBlockView(block: ratingBlock) {
                    onShowRatingResults(post.postID)
                }
            }

            if !post.comments.isEmpty {
                ForumThreadCommentsView(comments: post.comments, onUserTap: onUserTap)
            }

            if !post.attachments.isEmpty {
                ForumThreadFooterAttachmentsView(attachments: post.attachments, onURLTap: onURLTap)
            }

            ForumThreadPostActionRow(
                replyURL: YamiboRoute.threadPostReply(tid: threadID, pid: post.postID, page: currentPage).url,
                onRate: {
                    isShowingRateSheet = true
                },
                onComment: {
                    isShowingCommentSheet = true
                },
                onURLTap: onURLTap
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground(fill: isTarget ? ForumColors.accentFill : ForumColors.creamSurface)
        .sheet(isPresented: $isShowingRateSheet) {
            ForumThreadRateSheet(
                postID: post.postID,
                loadOptions: onLoadRateOptions,
                submit: onRatePost
            )
        }
        .sheet(isPresented: $isShowingCommentSheet) {
            ForumThreadCommentSheet(
                postID: post.postID,
                submit: onCommentPost
            )
        }
    }
}

private struct ForumThreadPostActionRow: View {
    let replyURL: URL
    let onRate: () -> Void
    let onComment: () -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider()
                .overlay(ForumColors.brownLight.opacity(0.25))

            HStack {
                Spacer(minLength: 0)
                Button(action: onRate) {
                    Label(L10n.string("forum.thread.rate"), systemImage: "heart")
                        .font(.caption.weight(.semibold))
                        .expandedHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForumColors.brownPrimary)

                Button(action: onComment) {
                    Label(L10n.string("forum.thread.comment"), systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                        .expandedHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForumColors.brownPrimary)

                Button {
                    onURLTap(replyURL)
                } label: {
                    Label(L10n.string("forum.thread.reply"), systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .expandedHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForumColors.brownPrimary)
            }
        }
    }
}

private struct ForumThreadPostEditedTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(ForumColors.secondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

private struct ForumThreadPostTitleHeader: View {
    let title: String
    let totalViews: Int?
    let totalReplies: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ForumColors.textDark)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if totalViews != nil || totalReplies != nil {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let totalViews {
                        ForumThreadStatBadge(systemImage: "eye", value: totalViews)
                    }
                    if let totalReplies {
                        ForumThreadStatBadge(systemImage: "text.bubble", value: totalReplies)
                    }
                }
            }
        }
    }
}

private struct ForumThreadStatBadge: View {
    let systemImage: String
    let value: Int

    var body: some View {
        Label {
            Text(value.formatted())
                .font(.caption.weight(.semibold))
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(ForumColors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ForumColors.creamBackground, in: Capsule())
    }
}
