import XCTest
@testable import YamiboXUI

#if os(iOS)
@MainActor
final class ClipboardForumLinkPasteboardReaderTests: XCTestCase {
    func testDoesNotReadClipboardStringWhenPasteboardHasNoWebURLPattern() async {
        let reader = ClipboardForumLinkPasteboardReader()
        let pasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: false,
            string: "bbs.yamibo.com/thread-100-1-1.html"
        )

        let url = await reader.promptURL(from: pasteboard)

        XCTAssertNil(url)
        XCTAssertEqual(pasteboard.containsWebURLPatternCallCount, 1)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
    }

    func testReadsClipboardStringOnlyAfterWebURLPatternDetection() async throws {
        let reader = ClipboardForumLinkPasteboardReader()
        let pasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "bbs.yamibo.com/thread-101-1-1.html"
        )

        let promptURL = await reader.promptURL(from: pasteboard)
        let url = try XCTUnwrap(promptURL)

        XCTAssertEqual(url.absoluteString, "https://bbs.yamibo.com/thread-101-1-1.html?mobile=2")
        XCTAssertEqual(pasteboard.containsWebURLPatternCallCount, 1)
        XCTAssertEqual(pasteboard.stringReadCount, 1)
    }

    func testNoWebURLPatternBreaksConsecutiveDuplicateSuppressionWithoutReadingString() async throws {
        let reader = ClipboardForumLinkPasteboardReader()
        let firstPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "bbs.yamibo.com/thread-102-1-1.html"
        )
        let noURLPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: false,
            string: nil
        )
        let repeatedPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "bbs.yamibo.com/thread-102-1-1.html"
        )

        let firstPromptURL = await reader.promptURL(from: firstPasteboard)
        let noURLPromptURL = await reader.promptURL(from: noURLPasteboard)
        let repeatedPromptURL = await reader.promptURL(from: repeatedPasteboard)
        let firstURL = try XCTUnwrap(firstPromptURL)
        let repeatedURL = try XCTUnwrap(repeatedPromptURL)

        XCTAssertNil(noURLPromptURL)
        XCTAssertEqual(repeatedURL, firstURL)
        XCTAssertEqual(noURLPasteboard.stringReadCount, 0)
    }

    func testNonForumWebURLBreaksConsecutiveDuplicateSuppression() async throws {
        let reader = ClipboardForumLinkPasteboardReader()
        let firstPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "bbs.yamibo.com/thread-103-1-1.html"
        )
        let nonForumPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "https://example.com/"
        )
        let repeatedPasteboard = FakeClipboardForumLinkPasteboard(
            containsWebURLPattern: true,
            string: "bbs.yamibo.com/thread-103-1-1.html"
        )

        let firstPromptURL = await reader.promptURL(from: firstPasteboard)
        let nonForumPromptURL = await reader.promptURL(from: nonForumPasteboard)
        let repeatedPromptURL = await reader.promptURL(from: repeatedPasteboard)
        let firstURL = try XCTUnwrap(firstPromptURL)
        let repeatedURL = try XCTUnwrap(repeatedPromptURL)

        XCTAssertNil(nonForumPromptURL)
        XCTAssertEqual(repeatedURL, firstURL)
    }
}

private final class FakeClipboardForumLinkPasteboard: ClipboardForumLinkPasteboardReading {
    private let containsWebURLPatternResult: Bool
    private let clipboardString: String?
    private(set) var containsWebURLPatternCallCount = 0
    private(set) var stringReadCount = 0

    init(containsWebURLPattern: Bool, string: String?) {
        containsWebURLPatternResult = containsWebURLPattern
        clipboardString = string
    }

    func containsWebURLPattern() async -> Bool {
        containsWebURLPatternCallCount += 1
        return containsWebURLPatternResult
    }

    var string: String? {
        stringReadCount += 1
        return clipboardString
    }
}
#endif
