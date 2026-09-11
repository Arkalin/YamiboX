import XCTest

@MainActor
final class ChapterCommentComposerInteractionTests: XCTestCase {
    func testOwnerDraftSwitchingAndSingleTapReplyReturnsToComments() throws {
        let app = launch()
        defer { app.terminate() }
        app.buttons["chapter-comment-compose"].tap()
        let comment = app.textViews["chapter-comment-text"]
        XCTAssertTrue(comment.waitForExistence(timeout: 8))
        let target = app.descendants(matching: .any).matching(identifier: "chapter-comment-target").firstMatch
        XCTAssertTrue(target.label.contains("南枝"), target.label)
        XCTAssertFalse(target.label.contains("匿名"), target.label)
        comment.tap()
        comment.typeText("Comment draft")
        select("评分", app: app)
        let score = app.textFields["chapter-comment-score"]
        XCTAssertTrue(score.waitForExistence(timeout: 5))
        score.tap()
        score.typeText("2")
        select("回复", app: app)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(warning(app).exists)
        XCTAssertTrue(warning(app).label.contains("不会出现在当前章节评论区"))
        XCTAssertFalse(app.buttons["chapter-comment-send"].isEnabled)
        editor.tap()
        editor.typeText("Reply draft")
        attach(app, "chapter-composer-reply-keyboard")
        select("点评", app: app)
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        XCTAssertTrue((comment.value as? String)?.contains("Comment draft") == true)
        XCTAssertFalse(warning(app).exists)
        select("评分", app: app)
        XCTAssertEqual(score.value as? String, "2")
        attach(app, "chapter-composer-rating")
        select("回复", app: app)
        XCTAssertTrue((editor.value as? String)?.contains("Reply draft") == true)
        app.buttons["chapter-comment-send"].tap()
        waitForComposerDismissal(app)
        let diagnostics = app.staticTexts["chapter-comment-diagnostics"]
        XCTAssertTrue(diagnostics.label.contains("count=1;mode=reply;pid=456;page=9"), diagnostics.label)
        attach(app, "chapter-composer-returned")
    }

    func testIndependentReplyTargetAndFailedSubmissionKeepDraft() throws {
        let app = launch(extra: ["CHAPTER_COMMENT_SEND_FAIL": "1"])
        defer { app.terminate() }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapter-comment-reply-")).count, 1)
        app.buttons["chapter-comment-reply-789"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertFalse(warning(app).exists)
        let target = app.descendants(matching: .any).matching(identifier: "chapter-comment-target").firstMatch
        XCTAssertTrue(target.label.contains("见微"), target.label)
        editor.tap()
        editor.typeText("Keep failed reply")
        app.buttons["chapter-comment-send"].tap()
        XCTAssertTrue(app.buttons["toast-failure-details"].waitForExistence(timeout: 8))
        XCTAssertTrue(editor.exists)
        XCTAssertTrue((editor.value as? String)?.contains("Keep failed reply") == true)
        app.buttons["chapter-comment-send"].tap()
        waitForComposerDismissal(app)
        XCTAssertTrue(app.staticTexts["chapter-comment-diagnostics"].label.contains("count=2;mode=reply;pid=789;page=9"))
    }

    func testCloseProtectsDraftFromOtherMode() throws {
        let app = launch()
        defer { app.terminate() }
        app.buttons["chapter-comment-compose"].tap()
        let editor = app.textViews["chapter-comment-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        editor.typeText("Keep this comment")
        select("回复", app: app)
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.buttons["chapter-comment-close"].tap()
        let discard = app.sheets.buttons["放弃并离开"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        let cancel = app.sheets.buttons["取消"]
        if cancel.exists {
            cancel.tap()
        } else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.exists)
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        }
        let dialogDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: discard)
        XCTAssertEqual(XCTWaiter.wait(for: [dialogDismissed], timeout: 5), .completed)
        select("点评", app: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Keep this comment") == true)
        app.buttons["chapter-comment-close"].tap()
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        waitForComposerDismissal(app)
        XCTAssertTrue(app.staticTexts["chapter-comment-diagnostics"].label.contains("count=0"))
    }

    func testWarningVariantsAndDarkLargeText() throws {
        for variant in ["latest", "unknown", "manga", "large"] {
            var extra: [String: String] = [:]
            if variant == "manga" { extra["CHAPTER_COMMENT_READER"] = "manga" }
            else if variant == "large" {
                extra["CHAPTER_COMMENT_DARK"] = "1"
                extra["CHAPTER_COMMENT_LARGE_TEXT"] = "1"
            } else { extra["CHAPTER_COMMENT_BOUNDARY"] = variant }
            let app = launch(extra: extra)
            app.buttons["chapter-comment-compose"].tap()
            XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 8))
            select("回复", app: app)
            XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(warning(app).exists, variant == "unknown" || variant == "large")
            if variant == "unknown" { XCTAssertTrue(warning(app).label.contains("可能不会")) }
            XCTAssertTrue(app.buttons["chapter-comment-close"].isHittable)
            XCTAssertTrue(app.segmentedControls.firstMatch.isHittable)
            attach(app, "chapter-composer-\(variant)")
            app.terminate()
        }
    }

    func testOwnPostRatingShowsReasonWithoutFormOrLogin() throws {
        for largeText in [false, true] {
            var extra = ["CHAPTER_COMMENT_RATE_FAIL": "own"]
            if largeText {
                extra["CHAPTER_COMMENT_LARGE_TEXT"] = "1"
                extra["CHAPTER_COMMENT_DARK"] = "1"
            }
            let app = launch(extra: extra)
            defer { app.terminate() }
            app.buttons["chapter-comment-compose"].tap()
            XCTAssertTrue(app.textViews["chapter-comment-text"].waitForExistence(timeout: 8))
            select("评分", app: app)
            let reason = app.staticTexts["抱歉，您不能给自己发表的帖子评分"]
            XCTAssertTrue(reason.waitForExistence(timeout: 5))
            XCTAssertTrue(reason.isHittable)
            XCTAssertTrue(app.staticTexts["无法评分"].exists)
            XCTAssertFalse(app.textFields["chapter-comment-score"].exists)
            XCTAssertFalse(app.buttons["chapter-comment-web-login"].exists)
            XCTAssertFalse(app.buttons["重试"].exists)
            XCTAssertFalse(app.buttons["chapter-comment-send"].isEnabled)
            attach(app, largeText ? "own-rating-dark-large" : "own-rating-unavailable")
            select("点评", app: app)
            XCTAssertTrue(app.textViews["chapter-comment-text"].waitForExistence(timeout: 5))
            select("评分", app: app)
            XCTAssertTrue(reason.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["chapter-comment-web-login"].exists)
            app.buttons["chapter-comment-close"].tap()
            waitForComposerDismissal(app)
            XCTAssertTrue(app.staticTexts["chapter-comment-diagnostics"].label.contains("count=0"))
        }
    }

    func testLoadFailureLoginActionFollowsAuthenticationType() throws {
        for source in ["CONTEXT", "RATE", "REPLY"] {
            for error in ["auth", "offline"] {
                let app = launch(extra: ["CHAPTER_COMMENT_\(source)_FAIL": error])
                defer { app.terminate() }
                app.buttons["chapter-comment-compose"].tap()
                if source != "CONTEXT" {
                    XCTAssertTrue(app.textViews["chapter-comment-text"].waitForExistence(timeout: 8))
                    select(source == "RATE" ? "评分" : "回复", app: app)
                }
                XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 8))
                XCTAssertEqual(app.buttons["chapter-comment-web-login"].exists, error == "auth")
                XCTAssertFalse(app.buttons["chapter-comment-send"].isEnabled)
                if source == "CONTEXT" {
                    select("评分", app: app)
                    XCTAssertTrue(app.buttons["重试"].exists)
                    XCTAssertEqual(app.buttons["chapter-comment-web-login"].exists, error == "auth")
                }
                attach(app, "\(source.lowercased())-\(error)-recovery")
            }
        }
    }

    func testSubmissionFailureOnlyOffersLoginForAuthentication() throws {
        for error in ["auth", "offline"] {
            let app = launch(extra: ["CHAPTER_COMMENT_SEND_FAIL": error])
            defer { app.terminate() }
            app.buttons["chapter-comment-compose"].tap()
            let editor = app.textViews["chapter-comment-text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 8))
            editor.tap()
            editor.typeText("Keep my draft")
            app.buttons["chapter-comment-send"].tap()
            XCTAssertTrue(app.buttons["toast-failure-details"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.buttons["chapter-comment-web-login"].exists, error == "auth")
            XCTAssertTrue((editor.value as? String)?.contains("Keep my draft") == true)
            attach(app, "submit-\(error)-recovery")
        }
    }

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CHAPTER_COMMENT_FIXTURE"] = "1"
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["chapter-comment-compose"].waitForExistence(timeout: 10))
        return app
    }

    private func select(_ title: String, app: XCUIApplication) {
        let button = app.segmentedControls.firstMatch.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let tappable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [tappable], timeout: 5), .completed)
        button.tap()
    }

    private func waitForComposerDismissal(_ app: XCUIApplication) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.buttons["chapter-comment-close"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["chapter-comment-compose"].isHittable)
    }

    private func warning(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chapter-comment-placement-warning").firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
