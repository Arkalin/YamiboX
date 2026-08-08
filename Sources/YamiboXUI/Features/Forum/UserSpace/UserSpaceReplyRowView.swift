import SwiftUI
import YamiboXCore

struct UserSpaceReplyRowView: View {
    @Environment(\.forumTheme) private var theme
    let reply: UserSpaceReplyGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(reply.threadTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                if let excerpt = reply.excerpt {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(3)
                }
                if let lastActivityText = reply.lastActivityText {
                    Text(lastActivityText)
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .forumCardBackground()
        }
        .buttonStyle(.plain)
    }
}
