import SwiftUI
import YamiboXCore

struct UserSpaceViewAllBlogFilterView: View {
    let selectedFilter: UserSpaceViewAllBlogFilter
    let selectFilter: (UserSpaceViewAllBlogFilter) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(UserSpaceViewAllBlogFilter.allCases, id: \.self) { filter in
                Button {
                    selectFilter(filter)
                } label: {
                    Text(title(for: filter))
                        .font(.footnote.weight(filter == selectedFilter ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .expandedHitTarget(width: 0)
                }
                .buttonStyle(.bordered)
                .tint(filter == selectedFilter ? ForumColors.brownEmphasis : ForumColors.brownLight)
                .accessibilityAddTraits(filter == selectedFilter ? .isSelected : [])
            }
        }
    }

    private func title(for filter: UserSpaceViewAllBlogFilter) -> String {
        switch filter {
        case .latest:
            L10n.string("user_space.blog_filter_latest")
        case .hot:
            L10n.string("user_space.blog_filter_hot")
        }
    }
}
