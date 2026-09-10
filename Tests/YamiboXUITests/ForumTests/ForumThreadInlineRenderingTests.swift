import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class ForumThreadInlineRenderingTests: XCTestCase {
    @MainActor
    func testChapterCommentBodyPreservesImageAttributesAndRendersAtPhoneAndTabletWidths() throws {
        let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "Chapter")
        let html = """
        <div id='comment_100'><div class='pstl'><div class='psti'>
        前😀<img src='static/image/smiley/default/smile.gif'>后
        </div></div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        let comment = try XCTUnwrap(page.comments.first)
        let body = ReaderChapterCommentBody(text: comment.body, blocks: comment.bodyBlocks, refererURL: YamiboDomain.baseURL)
        XCTAssertEqual(String(body.attributedText.characters), "前😀\u{FFFC}后")
        XCTAssertEqual(body.attributedText.runs.compactMap { $0[ForumThreadInlineImageKey.self] }.count, 1)
        let plain = ReaderChapterCommentBody(text: comment.body, blocks: nil, refererURL: YamiboDomain.baseURL)
        XCTAssertEqual(String(plain.attributedText.characters), "前😀后")
        for width: CGFloat in [280, 700] {
            let renderer = ImageRenderer(content: body.frame(width: width, alignment: .leading).background(.white))
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThanOrEqual(image.size.height, 28)
            attach(image, name: "Chapter Comment Emoticon \(Int(width))")
        }
    }

    @MainActor
    func testChineseItalicChangesPixelsWithoutChangingLineLayout() throws {
        let plain = ForumThreadTextBlock(text: "中文斜体 Abc")
        var italic = plain
        italic.styleRuns = [ForumThreadTextStyleRun(start: 0, length: 4, style: ForumThreadTextStyle(isItalic: true))]
        let plainImage = try render(plain, width: 320)
        let italicImage = try render(italic, width: 320)
        XCTAssertEqual(plainImage.size, italicImage.size)
        XCTAssertNotEqual(plainImage.pngData(), italicImage.pngData())
        attach(italicImage, name: "Chinese Italic")
        let baseline: CGFloat = 20
        let transform = ForumThreadTextRenderer.italicTransform(baseline: baseline)
        XCTAssertEqual(CGPoint(x: 10, y: baseline).applying(transform).x, 10, accuracy: 0.001)
        XCTAssertGreaterThan(CGPoint(x: 10, y: 0).applying(transform).x, 10)
    }

    @MainActor
    func testEmoticonsFlowWithTextAndOnlyWrapWhenNeeded() throws {
        let image = ForumThreadImageBlock(url: URL(string: "https://bbs.yamibo.com/static/image/smiley/smile.gif")!, altText: "表情", isEmoticon: true)
        let block = ForumThreadTextBlock(text: "前\u{FFFC}\u{FFFC}后", inlineImages: [
            ForumThreadInlineImage(start: 1, image: image),
            ForumThreadInlineImage(start: 2, image: image)
        ])
        let wide = try render(block, width: 320)
        let narrow = try render(block, width: 70)
        XCTAssertLessThan(wide.size.height, 45)
        XCTAssertGreaterThan(narrow.size.height, wide.size.height)
        attach(wide, name: "Inline Emoticons")
        attach(narrow, name: "Wrapped Emoticons")

        var explicitBreak = block
        explicitBreak.text = "前\u{FFFC}\u{FFFC}\n后"
        XCTAssertGreaterThan(try render(explicitBreak, width: 320).size.height, wide.size.height)
    }

    @MainActor
    func testStyledInlineContentAtPhoneAndTabletWidths() throws {
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: """
        正常正文，<i>这是中文斜体 English</i>。<br>
        <b><i>粗斜体</i></b>，<u>下划线</u>，<font color="red">红色</font>。
        <img src="static/image/smiley/default/smile.gif" alt="微笑">表情后继续正文。
        <img src="static/image/smiley/default/smile.gif" alt="微笑"><img src="static/image/smiley/default/smile.gif" alt="微笑">
        <br><a href="https://bbs.yamibo.com/thread-1-1-1.html">帖子链接</a>
        """)
        guard case let .text(block) = try XCTUnwrap(blocks.first).kind else { return XCTFail("Expected text") }
        for width: CGFloat in [280, 700] {
            attach(try render(block, width: width), name: "Styled Inline Content \(Int(width))")
        }
    }

    @MainActor
    private func render(_ block: ForumThreadTextBlock, width: CGFloat) throws -> UIImage {
        let attributed = ForumThreadTextBlockFormatter(block: block).attributedText
        let symbol = ForumThreadInlineTextView.sizedImage(try XCTUnwrap(UIImage(systemName: "face.smiling.fill")), dimension: 28)
        let images = Dictionary(block.inlineImages.map { ($0.image.url, symbol) }, uniquingKeysWith: { first, _ in first })
        let view = ForumThreadInlineTextView.composedText(attributed, images: images, imageSize: 28)
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(.black)
            .textRenderer(ForumThreadTextRenderer())
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
