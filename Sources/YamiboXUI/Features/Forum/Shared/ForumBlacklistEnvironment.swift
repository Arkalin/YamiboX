import SwiftUI
import YamiboXCore

extension EnvironmentValues {
    @Entry var forumBlacklist: ForumBlacklistWorkflow? = nil
}

struct ForumBlockedContentView: View {
    @Environment(\.forumTheme) private var theme
    var floor: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.slash")
            Text(L10n.string("blacklist.blocked_reply"))
            Spacer(minLength: 0)
            if let floor { Text(floor).font(.caption) }
        }
        .font(.subheadline)
        .foregroundStyle(theme.secondaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ForumBlacklistEmptyView: View {
    var body: some View {
        ContentUnavailableView(L10n.string("blacklist.filtered_page"), systemImage: "person.slash")
            .frame(maxWidth: .infinity)
    }
}
