import SwiftUI
import YamiboXCore

struct ForumThreadContentBlocksView: View {
    let blocks: [ForumThreadContentBlock]
    let fallbackText: String
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                ForumThreadTextBlockView(
                    block: ForumThreadTextBlock(text: fallbackText),
                    onURLTap: onURLTap
                )
            } else {
                ForEach(blocks) { block in
                    ForumThreadContentBlockView(
                        block: block,
                        refererURL: refererURL,
                        onImageTap: onImageTap,
                        onURLTap: onURLTap
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ForumThreadContentBlockView: View {
    let block: ForumThreadContentBlock
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        switch block.kind {
        case let .text(textBlock):
            ForumThreadTextBlockView(block: textBlock, onURLTap: onURLTap)
        case let .image(imageBlock):
            ForumThreadImageBlockView(
                blockID: block.id,
                block: imageBlock,
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )
        case let .attachment(attachment):
            ForumThreadAttachmentBlockView(block: attachment, onURLTap: onURLTap)
        case let .quote(blocks):
            ForumThreadNestedBlockContainer(accented: true) {
                ForumThreadContentBlocksView(
                    blocks: blocks,
                    fallbackText: "",
                    refererURL: refererURL,
                    onImageTap: onImageTap,
                    onURLTap: onURLTap
                )
            }
        case let .code(text):
            ForumThreadCodeBlockView(text: text)
        case .horizontalRule:
            Divider()
                .overlay(ForumColors.brownLight.opacity(0.35))
        case let .collapse(title, blocks):
            ForumThreadDisclosureBlockView(
                title: title ?? L10n.string("forum.thread.collapse_title"),
                blocks: blocks,
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )
        case let .locked(cost, blocks):
            ForumThreadLockedBlockView(
                cost: cost,
                blocks: blocks,
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )
        case let .table(rows):
            ForumThreadTableBlockView(
                rows: rows,
                refererURL: refererURL,
                onImageTap: onImageTap,
                onURLTap: onURLTap
            )
        }
    }
}

struct ForumThreadNestedBlockContainer<Content: View>: View {
    let accented: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if accented {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ForumColors.brownPrimary)
                    .frame(width: 4)
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}
