import XCTest

@MainActor final class ChapterCommentDiscussionInteractionTests: XCTestCase {
    func testBackgroundLoadingGroupsRepliesAndShowsAuthorAndDeepReplyPrefix() {
        let app = launch()
        defer { app.terminate() }
        let replies = app.buttons["chapter-comment-replies-root"]
        XCTAssertTrue(replies.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["加载下一页"].exists)
        XCTAssertTrue(app.buttons["chapter-comment-reply-789"].exists)
        XCTAssertEqual(app.buttons["chapter-comment-reply-789"].label, "评论")
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "共 4 条回复"), object: replies)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-child"].exists)
        attach(app, "chapter-discussions-root")
        replies.tap()
        XCTAssertTrue(app.navigationBars["评论详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chapter-comment-body-child"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["作者"].exists)
        XCTAssertTrue(app.staticTexts["chapter-comment-body-remark"].label.contains("回复 南枝：谢谢解答！"))
        XCTAssertTrue(app.staticTexts["chapter-comment-body-nested"].label.contains("回复 南枝：再读一遍"))
        XCTAssertFalse(app.buttons["chapter-comment-reply-rating"].exists)
        attach(app, "chapter-discussions-replies")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(replies.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chapter-comment-body-child"].exists)
    }

    func testHiddenParentKeepsRepliesAndRetryContinuesBackgroundLoad() {
        let app = launch(extra: ["CHAPTER_COMMENT_HIDE_ROOT": "1", "CHAPTER_COMMENT_PAGE_FAIL": "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["该评论已过滤"].waitForExistence(timeout: 8))
        let retry = app.buttons["chapter-comments-retry-more"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        retry.tap()
        let replies = app.buttons["chapter-comment-replies-root"]
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "共 4 条回复"), object: replies)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 10), .completed)
        replies.tap()
        XCTAssertTrue(app.staticTexts["作者"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["该评论已过滤"].exists)
    }

    func testNestedCommentSubmissionReturnsToSameDiscussion() {
        let app = launch()
        defer { app.terminate() }
        let replies = app.buttons["chapter-comment-replies-root"]
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "共 4 条回复"), object: replies)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 12), .completed)
        replies.tap()
        let comment = app.buttons["chapter-comment-reply-790"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        XCTAssertTrue(app.segmentedControls.buttons["点评"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["点评"].tap()
        let editor = app.textViews["chapter-comment-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Nested comment")
        app.buttons["chapter-comment-send"].tap()
        let added = app.staticTexts["chapter-comment-body-submitted-0"]
        XCTAssertTrue(added.waitForExistence(timeout: 12))
        if !added.isHittable { app.swipeUp() }
        XCTAssertTrue(added.label.contains("回复 南枝：Nested comment"))
        attach(app, "chapter-discussions-submission")
    }

    func testDarkLargeTextRepliesRemainNavigable() {
        let app = launch(extra: ["CHAPTER_COMMENT_DARK": "1", "CHAPTER_COMMENT_LARGE_TEXT": "1"])
        defer { app.terminate() }
        let replies = app.buttons["chapter-comment-replies-root"]
        XCTAssertTrue(replies.waitForExistence(timeout: 8))
        replies.tap()
        let child = app.buttons["chapter-comment-reply-790"]
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        let composeBar = app.buttons["chapter-comment-compose"]
        for _ in 0..<4 where !child.isHittable || child.frame.maxY >= composeBar.frame.minY { app.swipeUp() }
        XCTAssertTrue(child.isHittable)
        XCTAssertLessThan(child.frame.maxY, composeBar.frame.minY)
        XCTAssertGreaterThanOrEqual(child.frame.height, 44)
        XCTAssertGreaterThanOrEqual(child.frame.width, 44)
        XCTAssertLessThanOrEqual(child.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(app.staticTexts["chapter-comment-body-child"].frame.height, 60)
        attach(app, "chapter-discussions-dark-large")
    }

    func testConversationAppendsItsWholeBranchWithoutOtherBranchesOrComposeBar() {
        let app = launch(extra: ["CHAPTER_COMMENT_CONVERSATION_FIXTURE": "1", "CHAPTER_COMMENT_CONVERSATION_DELAY": "12"])
        defer { app.terminate() }
        openDetails(app)
        let root = app.otherElements["chapter-comment-row-root"]
        let firstReply = app.otherElements["chapter-comment-row-rating"]
        XCTAssertGreaterThanOrEqual(firstReply.frame.minY - root.frame.maxY, 8)
        XCTAssertFalse(app.buttons["chapter-comment-conversation-child"].exists)
        let entry = app.buttons["chapter-comment-conversation-remark"]
        reveal(entry, in: app)
        XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
        // The 44pt hit frame extends above and below the compact, centered label.
        let labelOffset = entry.frame.midY - app.staticTexts["2026-09-12 12:41"].frame.maxY
        XCTAssertGreaterThan(labelOffset, 0)
        XCTAssertLessThanOrEqual(labelOffset, 16)
        let previousY = entry.frame.minY
        entry.tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chapter-comment-body-child"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-root"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-rating"].exists)
        XCTAssertFalse(app.buttons["chapter-comment-compose"].exists)
        XCTAssertFalse(app.buttons["chapter-comment-conversation-remark"].exists)
        let firstY = app.staticTexts["chapter-comment-body-child"].frame.minY
        let deep = app.staticTexts["chapter-comment-body-deep"]
        XCTAssertTrue(deep.waitForExistence(timeout: 18))
        XCTAssertEqual(app.staticTexts["chapter-comment-body-child"].frame.minY, firstY, accuracy: 2)
        XCTAssertTrue(deep.label.contains("回复 远山："))
        let deepComment = app.buttons["chapter-comment-reply-792"]
        reveal(deepComment, in: app)
        deepComment.tap()
        let deepTarget = app.descendants(matching: .any).matching(identifier: "chapter-comment-target").firstMatch
        XCTAssertTrue(deepTarget.waitForExistence(timeout: 5))
        XCTAssertTrue(deepTarget.label.contains("清溪"))
        app.buttons["chapter-comment-close"].tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["chapter-comment-body-branch-rating"], in: app)
        XCTAssertTrue(app.staticTexts["chapter-comment-body-branch-side"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-sibling"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-sibling-child"].exists)
        attach(app, "chapter-conversation-complete")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["评论详情"].waitForExistence(timeout: 5))
        XCTAssertEqual(entry.frame.minY, previousY, accuracy: 3)
        reveal(app.buttons["chapter-comment-conversation-branch-rating"], in: app)
        XCTAssertTrue(app.buttons["chapter-comment-conversation-branch-rating"].exists)
    }

    func testFilteredConversationRootAndRowSubmissionSurviveRefresh() {
        let app = launch(extra: ["CHAPTER_COMMENT_HIDE_BRANCH": "1"])
        defer { app.terminate() }
        openDetails(app)
        let entry = app.buttons["chapter-comment-conversation-remark"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["该评论已过滤"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-child"].exists)
        let comment = app.buttons["chapter-comment-reply-791"]
        reveal(comment, in: app)
        comment.tap()
        XCTAssertTrue(app.segmentedControls.buttons["点评"].waitForExistence(timeout: 5))
        let composeTarget = app.descendants(matching: .any).matching(identifier: "chapter-comment-target").firstMatch
        XCTAssertTrue(composeTarget.label.contains("远山"))
        app.segmentedControls.buttons["点评"].tap()
        let editor = app.textViews["chapter-comment-text"]
        editor.tap()
        editor.typeText("Conversation comment")
        app.buttons["chapter-comment-send"].tap()
        let added = app.staticTexts["chapter-comment-body-submitted-0"]
        XCTAssertTrue(added.waitForExistence(timeout: 12))
        XCTAssertTrue(added.label.contains("回复 远山：Conversation comment"))
        XCTAssertTrue(app.navigationBars["对话列表"].exists)
        XCTAssertTrue(app.staticTexts["该评论已过滤"].exists)
        XCTAssertFalse(app.buttons["chapter-comment-compose"].exists)
        attach(app, "chapter-conversation-filtered-submission")
    }

    func testRemovedConversationReturnsToDetailsAfterRefreshCompletes() {
        let app = launch(extra: ["CHAPTER_COMMENT_CONVERSATION_FIXTURE": "1", "CHAPTER_COMMENT_REMOVE_CONVERSATION_ON_REFRESH": "1"])
        defer { app.terminate() }
        openDetails(app)
        let entry = app.buttons["chapter-comment-conversation-remark"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["刷新"].tap()
        XCTAssertTrue(app.navigationBars["评论详情"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["chapter-comment-body-sibling"].exists)
        XCTAssertFalse(app.staticTexts["chapter-comment-body-child"].exists)
    }

    func testDarkLargeTextConversationRemainsReadableAndNavigable() {
        let app = launch(extra: ["CHAPTER_COMMENT_DARK": "1", "CHAPTER_COMMENT_LARGE_TEXT": "1"])
        defer { app.terminate() }
        openDetails(app)
        let entry = app.buttons["chapter-comment-conversation-nested"]
        reveal(entry, in: app)
        XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
        XCTAssertLessThanOrEqual(entry.frame.maxX, app.frame.maxX)
        entry.tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 5))
        let root = app.staticTexts["chapter-comment-body-child"]
        XCTAssertTrue(root.exists)
        XCTAssertGreaterThan(root.frame.height, 60)
        XCTAssertFalse(app.buttons["chapter-comment-compose"].exists)
        let comment = app.buttons["chapter-comment-reply-791"]
        reveal(comment, in: app)
        XCTAssertGreaterThanOrEqual(comment.frame.height, 44)
        attach(app, "chapter-conversation-dark-large")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["评论详情"].waitForExistence(timeout: 5))
    }

    private func openDetails(_ app: XCUIApplication) {
        let replies = app.buttons["chapter-comment-replies-root"]
        XCTAssertTrue(replies.waitForExistence(timeout: 8))
        let metadata = app.staticTexts["28楼 · 2026-09-12 12:30"]
        XCTAssertGreaterThan(replies.frame.midY, metadata.frame.maxY)
        XCTAssertLessThanOrEqual(replies.frame.midY - metadata.frame.maxY, 24)
        replies.tap()
        XCTAssertTrue(app.navigationBars["评论详情"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 12))
        let composeBar = app.buttons["chapter-comment-compose"]
        for _ in 0..<8 {
            let bottom = composeBar.exists ? composeBar.frame.minY : app.frame.maxY - 24
            if element.isHittable && element.frame.maxY < bottom { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CHAPTER_COMMENT_DISCUSSION_FIXTURE"] = "1"
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
