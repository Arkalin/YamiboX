import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

// 拆分自 ReaderCoreTests.swift:阅读器文档 ownerPostID → 渲染页
// chapterCommentTarget 的投影链路(HTML 解析 → 投影 → NovelTextLayout)。

#if canImport(UIKit)
@Test func readerDocumentCarriesOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div class="t_f" id="postmessage_100">第一章<br>正文</div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "42",
        view: 3,
        authorID: "7"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "100")
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.view == 3)
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.title == "第一章")
}

@Test func readerDocumentCarriesNestedOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div id="post_595655">
        <div class="message">
          <div class="t_f" id="postmessage_595655">第一章<br>正文</div>
        </div>
      </div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1,
        authorID: "595655"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(document.segments.count == 1)
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "595655")
    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.view == 1)
}

@Test func readerDocumentCarriesAncestorOwnerPostIDToRenderedPages() throws {
    let html = """
    <html><body>
      <div id="pid41257246">
        <div class="message">作品名：测试<br>作者：测试</div>
      </div>
    </body></html>
    """
    let request = NovelPageRequest(
        threadID: "557752",
        view: 1,
        authorID: "595655"
    )

    let document = try chapterCommentsNovelProjection(from: html, request: request)
    let pagination = try NovelTextLayout.layout(
        document: document,
        settings: NovelReaderAppearanceSettings(),
        layout: NovelReaderLayout(width: 390, height: 844)
    )

    #expect(pagination.viewportIndex.surfaces.first?.chapterCommentTarget?.ownerPostID == "41257246")
}

private func chapterCommentsNovelProjection(
    from html: String,
    request: NovelPageRequest
) throws -> NovelReaderProjection {
    let page = try ForumThreadPageHTMLParser.parsePage(
        from: html,
        thread: ThreadIdentity(tid: request.threadID),
        fallbackTitle: nil
    )
    return try NovelReaderProjectionBuilder.build(
        from: page,
        request: request,
        authorID: request.authorID ?? "7"
    )
}
#endif
