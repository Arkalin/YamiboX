import SwiftUI
import YamiboXCore

struct ForumThreadCommentsView: View {
    @Environment(\.forumTheme) private var theme
    let comments: [ForumThreadPostComment]
    let onUserTap: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("forum.thread.comments"), systemImage: "text.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.mutedAccent)

            ForEach(comments) { comment in
                ForumThreadCommentRow(comment: comment, onUserTap: onUserTap)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ForumThreadCommentRow: View {
    @Environment(\.forumTheme) private var theme
    let comment: ForumThreadPostComment
    let onUserTap: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let uid = comment.author.uid {
                    Button {
                        onUserTap(uid, comment.author.name)
                    } label: {
                        Text(comment.author.name)
                            .expandedHitTarget(width: 0)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.mutedAccent)
                } else {
                    Text(comment.author.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mutedAccent)
                }

                Spacer(minLength: 0)

                if let postedAtText = comment.postedAtText {
                    Text(postedAtText)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text(comment.message)
                .font(.callout)
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
