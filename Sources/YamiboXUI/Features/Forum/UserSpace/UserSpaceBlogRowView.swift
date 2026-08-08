import SwiftUI
import YamiboXCore

struct UserSpaceBlogRowView: View {
    @Environment(\.forumTheme) private var theme
    let blog: UserSpaceBlogSummary
    let onUserTap: (String, String?) -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(blog.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    if let excerpt = blog.excerpt {
                        Text(excerpt)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
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
                    .foregroundStyle(theme.mutedAccent)
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
            .foregroundStyle(theme.secondaryText)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
