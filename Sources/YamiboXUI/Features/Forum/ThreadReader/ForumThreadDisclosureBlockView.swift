import SwiftUI
import YamiboXCore

struct ForumThreadDisclosureBlockView: View {
    @Environment(\.forumTheme) private var theme
    let title: String
    let blocks: [ForumThreadContentBlock]
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForumThreadContentBlocksView(
                blocks: blocks,
                fallbackText: "",
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
        }
        .padding(12)
        .background(theme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
