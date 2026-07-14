import SwiftUI
import YamiboXCore

struct UserSpaceBlogRowView: View {
    let blog: UserSpaceBlogSummary
    let onUserTap: (String, String?) -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(blog.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ForumColors.textDark)
                    if let excerpt = blog.excerpt {
                        Text(excerpt)
                            .font(.subheadline)
                            .foregroundStyle(ForumColors.secondaryText)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack {
                if let authorID = blog.authorID, let authorName = blog.authorName {
                    Button(authorName) {
                        onUserTap(authorID, authorName)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ForumColors.brownPrimary)
                }
                Spacer()
                if let viewCount = blog.viewCount {
                    Label(String(viewCount), systemImage: "eye")
                }
                if let replyCount = blog.replyCount {
                    Label(String(replyCount), systemImage: "bubble.right")
                }
            }
            .font(.caption)
            .foregroundStyle(ForumColors.secondaryText)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
