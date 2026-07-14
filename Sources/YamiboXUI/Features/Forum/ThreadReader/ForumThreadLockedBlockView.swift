import SwiftUI
import YamiboXCore

struct ForumThreadLockedBlockView: View {
    let cost: Int?
    let blocks: [ForumThreadContentBlock]
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumThreadNestedBlockContainer(accented: false) {
            VStack(alignment: .leading, spacing: 10) {
                Label(lockedText, systemImage: "lock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.orangeAccent)
                ForumThreadContentBlocksView(
                    blocks: blocks,
                    fallbackText: "",
                    refererURL: refererURL,
                    onImageTap: onImageTap,
                    onURLTap: onURLTap
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(ForumColors.orangeAccent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private var lockedText: String {
        if let cost {
            return L10n.string("forum.thread.locked_cost", cost)
        }
        return L10n.string("forum.thread.locked")
    }
}
