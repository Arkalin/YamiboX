import SwiftUI
import XCTest
import YamiboXCore
@testable import YamiboXUI

@MainActor
final class CreditLogLayoutTests: XCTestCase {
    func testRowsFitPhoneAndTabletWithLongTextAndMultipleChanges() throws {
        for width in [CGFloat(288), 600] {
            for scheme in [ColorScheme.light, .dark] {
                for typeSize in [DynamicTypeSize.large, .accessibility5] {
                    let view = CreditLogRowView(entry: entry, onURLTap: { _ in })
                        .padding(16)
                        .background(ForumTheme.teal.surface)
                        .forumTheme(.teal)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, typeSize)
                    let controller = UIHostingController(rootView: view)
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
                    XCTAssertEqual(size.width, width, accuracy: 0.5)
                    XCTAssertGreaterThan(size.height, 44)
                    XCTAssertLessThan(size.height, 1_800)
                    let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "credit-row-\(Int(width))-\(scheme)-\(typeSize)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    private var entry: CreditLogEntry {
        CreditLogEntry(
            id: "long-row",
            operation: "帖子被评分及积分兑换记录",
            changes: [
                CreditLogChange(name: "积分", valueText: "+123456", amount: 123456),
                CreditLogChange(name: "对象", valueText: "-2000", amount: -2000),
                CreditLogChange(name: "奖励积分清零", valueText: "")
            ],
            description: ForumThreadTextBlock(text: "Yamibo X：iOS端的百合会App，提供原生阅读体验与收藏管理。这是一条含有较长说明的积分记录。"),
            timeText: "2026-09-10 00:22"
        )
    }
}
