import Foundation
import YamiboXCore

enum ReaderChapterCommentImageGallery {
    static func request(
        comment: ChapterComment,
        target: ReaderChapterCommentTarget,
        selectedBlockID: String
    ) -> ForumThreadImageBrowserRequest? {
        let referer = comment.originalPostURL(threadID: target.threadID) ?? YamiboDomain.baseURL
        let chapterTitle = target.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultTitle = chapterTitle.isEmpty ? L10n.string("forum.thread.image") : chapterTitle
        let quotes = (comment.quoteBlocks ?? []).flatMap { block -> [ForumThreadContentBlock] in
            if case let .quote(children) = block.kind { return children }
            return []
        }
        let items = (quotes + (comment.contentBlocks ?? [])).compactMap { block -> ImageBrowserItem? in
            guard case let .image(image) = block.kind, !image.isEmoticon else { return nil }
            let title = image.altText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ImageBrowserItem(
                id: "\(comment.id):\(block.id)",
                source: YamiboImageSource(url: image.url, refererPageURL: referer),
                title: title.isEmpty ? defaultTitle : title
            )
        }
        let selectedID = "\(comment.id):\(selectedBlockID)"
        guard items.contains(where: { $0.id == selectedID }) else { return nil }
        return ForumThreadImageBrowserRequest(items: items, initialItemID: selectedID)
    }
}
