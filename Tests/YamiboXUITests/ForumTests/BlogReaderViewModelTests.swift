import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class BlogReaderViewModelTests: XCTestCase {
    func testLoadFetchesFirstBlogPage() async throws {
        let repository = BlogReaderRepositoryStub()
        let model = BlogReaderViewModel(blogID: "88", uid: "705216", titleHint: "日志标题", repository: repository)

        await model.load()

        XCTAssertEqual(model.page?.blogID, "88")
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.navigationTitle, "日志标题")
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["blog:88:705216:1"])
    }

    func testPaginationFetchesRequestedPage() async throws {
        let repository = BlogReaderRepositoryStub()
        let model = BlogReaderViewModel(blogID: "88", uid: nil, titleHint: nil, repository: repository)

        await model.load()
        await model.goToPage(2)

        XCTAssertEqual(model.page?.contentText, "第 2 页")
        XCTAssertEqual(model.currentPage, 2)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["blog:88:self:1", "blog:88:self:2"])
    }

    func testLoadStoresError() async throws {
        let repository = BlogReaderRepositoryStub(error: YamiboError.parsingFailed(context: "blog"))
        let model = BlogReaderViewModel(blogID: "88", uid: nil, titleHint: nil, repository: repository)

        await model.load()

        XCTAssertNil(model.page)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSubmitCommentUsesCurrentProfileFormHashClearsInputAndReloadsPage() async throws {
        let repository = BlogReaderRepositoryStub()
        let profile = YamiboProfile(
            uid: "705216",
            username: "我",
            userGroup: "百合花蕾",
            points: 0,
            partner: 0,
            totalPoints: 0,
            formHash: "form123"
        )
        let model = BlogReaderViewModel(
            blogID: "88",
            uid: "705216",
            titleHint: "日志标题",
            currentProfile: profile,
            repository: repository
        )

        await model.load()
        model.commentText = "  好文  "
        await model.submitComment()

        XCTAssertEqual(model.commentText, "")
        XCTAssertEqual(model.commentResultMessage, "评论发表成功")
        let calls = await repository.calls()
        XCTAssertEqual(calls, [
            "blog:88:705216:1",
            "comment:88:705216:form123:好文",
            "blog:88:705216:1"
        ])
    }

    func testSubmitCommentRequiresLoginFormHash() async throws {
        let repository = BlogReaderRepositoryStub()
        let model = BlogReaderViewModel(blogID: "88", uid: "705216", titleHint: nil, repository: repository)

        await model.load()
        model.commentText = "好文"
        await model.submitComment()

        XCTAssertNotNil(model.errorMessage)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["blog:88:705216:1"])
    }
}

private actor BlogReaderRepositoryStub: BlogReaderPageLoading {
    let error: Error?
    var recordedCalls: [String] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func fetchBlogPage(blogID: String, uid: String?, page: Int) async throws -> BlogReaderPage {
        recordedCalls.append("blog:\(blogID):\(uid ?? "self"):\(page)")
        if let error { throw error }
        return BlogReaderPage(
            blogID: blogID,
            title: "日志标题",
            author: BlogReaderUser(uid: uid, name: "张瑞泽"),
            postedAtText: "2026-06-01",
            contentHTML: "<p>第 \(page) 页</p>",
            contentText: "第 \(page) 页",
            viewCount: 42,
            replyCount: 3,
            comments: [],
            pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
        )
    }

    func postBlogComment(blogID: String, uid: String, message: String, formHash: String) async throws -> String {
        recordedCalls.append("comment:\(blogID):\(uid):\(formHash):\(message)")
        if let error { throw error }
        return "评论发表成功"
    }

    func calls() -> [String] {
        recordedCalls
    }
}
