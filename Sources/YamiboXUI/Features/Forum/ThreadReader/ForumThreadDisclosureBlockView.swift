import SwiftUI
import YamiboXCore

struct ForumThreadDisclosureBlockView: View {
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
                .foregroundStyle(ForumColors.textDark)
        }
        .padding(12)
        .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
