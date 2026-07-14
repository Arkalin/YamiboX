import SwiftUI
import YamiboXCore

struct UserSpaceReplyRowView: View {
    let reply: UserSpaceReplyGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(reply.threadTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ForumColors.textDark)
                if let excerpt = reply.excerpt {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(ForumColors.secondaryText)
                        .lineLimit(3)
                }
                if let lastActivityText = reply.lastActivityText {
                    Text(lastActivityText)
                        .font(.caption)
                        .foregroundStyle(ForumColors.brownLight)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .forumCardBackground()
        }
        .buttonStyle(.plain)
    }
}
