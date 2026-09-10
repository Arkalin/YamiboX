import SwiftUI
import YamiboXCore

struct UserSpaceSubPagePickerView: View {
    @Environment(\.forumTheme) private var theme
    let subPages: [UserSpaceSubPage]
    let selectedSubPage: UserSpaceSubPage
    let isSelf: Bool
    let selectSubPage: (UserSpaceSubPage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subPages, id: \.self) { subPage in
                    Button {
                        selectSubPage(subPage)
                    } label: {
                        Text(UserSpaceViewModel.title(for: subPage, isSelf: isSelf))
                            .font(.footnote.weight(subPage == selectedSubPage ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .foregroundStyle(subPage == selectedSubPage ? theme.primaryText : theme.secondaryText)
                            .background(Capsule().fill(subPage == selectedSubPage ? theme.selectedFill : theme.mutedFill))
                            .expandedHitTarget(width: 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(subPage == selectedSubPage ? .isSelected : [])
                }
            }
        }
    }
}
