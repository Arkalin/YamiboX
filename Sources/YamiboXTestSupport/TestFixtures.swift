import Foundation
import YamiboXCore

/// 由 NovelReadingSessionTests / NovelReadingSessionRuntimeTests 收敛出的共享
/// fixture(两份私有副本逐字节一致):按 (章节标题, 正文) 列表构造小说投影。
public func makeNovelDocument(
    view: Int,
    maxView: Int,
    segments: [(chapterTitle: String, text: String)]
) -> NovelReaderProjection {
    NovelReaderProjection(
        threadID: "9001",
        view: view,
        maxView: maxView,
        segments: segments.map { .text($0.text, chapterTitle: $0.chapterTitle) }
    )
}

/// 由 FavoriteUpdateNotificationTests / FavoriteUpdateMonitorTests 收敛出的共享
/// fixture(两份副本仅差 `title` 参数,这里取参数并集;Notification 侧沿用原来
/// 硬编码的默认标题 “更新主题”)。
public func makeThreadPage(
    threadID: String,
    postID: String,
    title: String = "更新主题",
    replyCount: Int,
    pageCount: Int
) throws -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: threadID, fid: "50"),
        title: title,
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: "u1", name: "作者"),
                contentHTML: "<p>正文</p>",
                contentText: "正文"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: pageCount),
        totalReplies: replyCount,
        forumID: "50",
        forumName: "测试板块"
    )
}
