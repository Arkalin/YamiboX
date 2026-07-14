import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class PrivateMessageViewModelTests: XCTestCase {
    func testLoadFetchesConversation() async throws {
        let repository = PrivateMessageRepositoryStub()
        let model = PrivateMessageViewModel(uid: "800001", titleHint: "好友A", repository: repository)

        await model.load()

        XCTAssertEqual(model.navigationTitle, "与 好友A 的短消息")
        XCTAssertEqual(model.page?.toUID, "800001")
        XCTAssertEqual(model.page?.messages.map(\.contentText), ["你好"])
        XCTAssertEqual(model.currentPage, 1)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["fetch:800001:nil:好友A"])
    }

    func testGoToPageFetchesRequestedConversationPage() async throws {
        let repository = PrivateMessageRepositoryStub()
        let model = PrivateMessageViewModel(uid: "800001", titleHint: "好友A", repository: repository)

        await model.goToPage(2)

        XCTAssertEqual(model.currentPage, 2)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["fetch:800001:2:好友A"])
    }

    func testSendUsesPageFormHashClearsInputAndReloadsConversation() async throws {
        let repository = PrivateMessageRepositoryStub()
        let model = PrivateMessageViewModel(uid: "800001", titleHint: "好友A", repository: repository)

        await model.load()
        model.inputText = "  收到  "
        await model.send()

        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.sendResultMessage, "短消息发送成功")
        let calls = await repository.calls()
        XCTAssertEqual(calls, [
            "fetch:800001:nil:好友A",
            "send:900:800001:hash123:收到",
            "fetch:800001:1:好友A"
        ])
    }

    func testSendReloadsCurrentConversationPage() async throws {
        let repository = PrivateMessageRepositoryStub()
        let model = PrivateMessageViewModel(uid: "800001", titleHint: "好友A", repository: repository)

        await model.goToPage(2)
        model.inputText = "  第二页回复  "
        await model.send()

        XCTAssertEqual(model.currentPage, 2)
        XCTAssertEqual(model.inputText, "")
        let calls = await repository.calls()
        XCTAssertEqual(calls, [
            "fetch:800001:2:好友A",
            "send:900:800001:hash123:第二页回复",
            "fetch:800001:2:好友A"
        ])
    }

    func testSendFallsBackToCurrentProfileFormHash() async throws {
        let repository = PrivateMessageRepositoryStub(formHash: nil)
        let profile = YamiboProfile(
            uid: "705216",
            username: "我",
            userGroup: "百合花蕾",
            points: 0,
            partner: 0,
            totalPoints: 0,
            formHash: "profileHash"
        )
        let model = PrivateMessageViewModel(
            uid: "800001",
            titleHint: "好友A",
            currentProfile: profile,
            repository: repository
        )

        await model.load()
        model.inputText = "收到"
        await model.send()

        let calls = await repository.calls()
        XCTAssertEqual(calls, [
            "fetch:800001:nil:好友A",
            "send:900:800001:profileHash:收到",
            "fetch:800001:1:好友A"
        ])
    }
}

private actor PrivateMessageRepositoryStub: PrivateMessagePageLoading {
    let formHash: String?
    var recordedCalls: [String] = []

    init(formHash: String? = "hash123") {
        self.formHash = formHash
    }

    func fetchPrivateMessagePage(uid: String, page: Int?, titleHint: String?) async throws -> PrivateMessagePage {
        recordedCalls.append("fetch:\(uid):\(page.map(String.init) ?? "nil"):\(titleHint ?? "")")
        let currentPage = page ?? 1
        return PrivateMessagePage(
            title: "与 \(titleHint ?? "好友") 的短消息",
            privateMessageID: "900",
            toUID: uid,
            toName: titleHint,
            formHash: formHash,
            messages: [
                PrivateMessage(
                    messageID: "1",
                    kind: .other,
                    author: PrivateMessageUser(uid: uid, name: titleHint ?? "好友"),
                    postedAtText: "2026-06-01 10:00",
                    contentHTML: "你好",
                    contentText: "你好"
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: currentPage, totalPages: 2)
        )
    }

    func sendPrivateMessage(privateMessageID: String, uid: String, formHash: String, message: String) async throws -> String {
        recordedCalls.append("send:\(privateMessageID):\(uid):\(formHash):\(message)")
        return "短消息发送成功"
    }

    func calls() -> [String] {
        recordedCalls
    }
}
