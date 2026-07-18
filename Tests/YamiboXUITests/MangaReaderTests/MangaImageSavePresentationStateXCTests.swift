import Foundation
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

// 拆分自 MangaReaderPresentationInfrastructureTests.swift:该文件历史上混装了
// Swift Testing 与 XCTest,这里把 XCTest 部分独立成文件(机械移动)。
// makePipelinePage fixture 保留在原文件(target 内 internal 可见)。

#if os(iOS)
final class MangaImageSavePresentationStateXCTests: XCTestCase {
    func testSuccessFeedbackIsAvailableWhileActionDialogDismisses() throws {
        let page = try makePipelinePage()
        var state = MangaImageSavePresentationState()

        state.presentActions(for: page)
        state.finishSave(with: .success)

        XCTAssertEqual(state.feedback?.message, L10n.string("image.save_success_message"))
    }
}
#endif
