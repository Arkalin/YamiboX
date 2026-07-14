import Foundation
import YamiboXCore

struct ForumThreadImageBrowserRequest: Identifiable, Equatable {
    var items: [ImageBrowserItem]
    var initialItemID: String

    var id: String {
        [
            initialItemID,
            items.map(\.id).joined(separator: "\u{1E}")
        ].joined(separator: "\u{1F}")
    }
}

struct ForumThreadImageBrowserGallery: Equatable {
    let items: [ImageBrowserItem]
    let initialItemID: String?

    init(
        page: ForumThreadPage,
        refererURL: URL,
        selectedBlockID: String,
        defaultTitle: String
    ) {
        let items = page.posts.flatMap { post in
            Self.items(
                in: post.contentBlocks,
                refererURL: refererURL,
                defaultTitle: defaultTitle
            )
        }
        self.items = items
        initialItemID = items.contains { $0.id == selectedBlockID }
            ? selectedBlockID
            : items.first?.id
    }

    private static func items(
        in blocks: [ForumThreadContentBlock],
        refererURL: URL,
        defaultTitle: String
    ) -> [ImageBrowserItem] {
        blocks.flatMap { block in
            items(
                in: block,
                refererURL: refererURL,
                defaultTitle: defaultTitle
            )
        }
    }

    private static func items(
        in block: ForumThreadContentBlock,
        refererURL: URL,
        defaultTitle: String
    ) -> [ImageBrowserItem] {
        switch block.kind {
        case let .image(imageBlock):
            guard !imageBlock.isEmoticon, imageBlock.linkURL == nil else { return [] }
            return [
                ImageBrowserItem(
                    id: block.id,
                    source: YamiboImageSource(url: imageBlock.url, refererPageURL: refererURL),
                    title: title(from: imageBlock.altText, defaultTitle: defaultTitle),
                )
            ]
        case let .quote(blocks):
            return items(in: blocks, refererURL: refererURL, defaultTitle: defaultTitle)
        case let .collapse(_, blocks):
            return items(in: blocks, refererURL: refererURL, defaultTitle: defaultTitle)
        case let .locked(_, blocks):
            return items(in: blocks, refererURL: refererURL, defaultTitle: defaultTitle)
        case let .table(rows):
            return rows.flatMap { row in
                row.flatMap { cell in
                    items(in: cell.blocks, refererURL: refererURL, defaultTitle: defaultTitle)
                }
            }
        case .text, .attachment, .code, .horizontalRule:
            return []
        }
    }

    private static func title(from altText: String?, defaultTitle: String) -> String {
        let trimmed = altText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultTitle : trimmed
    }
}
