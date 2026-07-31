import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

#if os(iOS)
final class ImageBrowserItemTests: XCTestCase {
    func testCaptionDefaultsToNilWithoutChangingExistingEquality() throws {
        let source = YamiboImageSource(
            url: try XCTUnwrap(URL(string: "https://img.example.com/page.jpg"))
        )
        let implicitNil = ImageBrowserItem(id: "image-1", source: source, title: "图片")
        let explicitNil = ImageBrowserItem(
            id: "image-1",
            source: source,
            title: "图片",
            caption: nil
        )

        XCTAssertNil(implicitNil.caption)
        XCTAssertEqual(implicitNil, explicitNil)
    }

    func testCaptionParticipatesInEquality() throws {
        let source = YamiboImageSource(
            url: try XCTUnwrap(URL(string: "https://img.example.com/page.jpg"))
        )
        let first = ImageBrowserItem(
            id: "image-1",
            source: source,
            title: "图片",
            caption: "第一条笔记"
        )
        let same = ImageBrowserItem(
            id: "image-1",
            source: source,
            title: "图片",
            caption: "第一条笔记"
        )
        let changed = ImageBrowserItem(
            id: "image-1",
            source: source,
            title: "图片",
            caption: "第二条笔记"
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, changed)
    }

    @MainActor
    func testCaptionPanelHugsShortTextAndCapsLongText() {
        let maximumHeight: CGFloat = 240
        let shortHeight = measuredHeight(
            of: ImageBrowserCaptionPanel(
                caption: "简短笔记",
                maximumHeight: maximumHeight
            )
        )
        let longHeight = measuredHeight(
            of: ImageBrowserCaptionPanel(
                caption: Array(repeating: "这是一段用于验证完整笔记可滚动阅读的内容。", count: 30).joined(),
                maximumHeight: maximumHeight
            )
        )

        XCTAssertLessThan(shortHeight, 100)
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertLessThanOrEqual(longHeight, maximumHeight)
    }

    @MainActor
    private func measuredHeight(of view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
