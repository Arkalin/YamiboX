import SwiftUI
import YamiboXCore

struct UserSpaceSubPagePickerView: View {
    let subPages: [UserSpaceSubPage]
    let selectedSubPage: UserSpaceSubPage
    let selectSubPage: (UserSpaceSubPage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subPages, id: \.self) { subPage in
                    Button {
                        selectSubPage(subPage)
                    } label: {
                        Text(title(for: subPage))
                            .font(.footnote.weight(subPage == selectedSubPage ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .foregroundStyle(subPage == selectedSubPage ? ForumColors.textDark : ForumColors.secondaryText)
                            .background(Capsule().fill(subPage == selectedSubPage ? ForumColors.accentFill : ForumColors.mutedFill))
                            .expandedHitTarget(width: 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(subPage == selectedSubPage ? .isSelected : [])
                }
            }
        }
    }

    private func title(for subPage: UserSpaceSubPage) -> String {
        switch subPage {
        case .profile:
            L10n.string("user_space.profile")
        case .threads:
            L10n.string("user_space.my_threads")
        case .replies:
            L10n.string("user_space.my_replies")
        case .myBlogs:
            L10n.string("user_space.my_blogs")
        case .friendBlogs:
            L10n.string("user_space.friend_blogs")
        case .viewAllBlogs:
            L10n.string("user_space.view_all_blogs")
        case .friends:
            L10n.string("user_space.my_friends")
        case .online:
            L10n.string("user_space.online")
        case .visitors:
            L10n.string("user_space.visitors")
        case .traces:
            L10n.string("user_space.traces")
        }
    }
}
