import SwiftUI
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class MessageUnreadBadgeTests: XCTestCase {
    func testCountProjectionAndAccessibilityUseActualCount() {
        XCTAssertNil(MessageUnreadBadge.text(for: 0))
        XCTAssertEqual(MessageUnreadBadge.text(for: 1), "1")
        XCTAssertEqual(MessageUnreadBadge.text(for: 99), "99")
        XCTAssertEqual(MessageUnreadBadge.text(for: 100), "99+")
        XCTAssertNil(MessageUnreadBadge.tabValue(for: 0))
        for count in [1, 99, 100] {
            XCTAssertEqual(MessageUnreadBadge.tabValue(for: count), "")
            XCTAssertEqual(
                MessageUnreadBadge.accessibilityValue(for: count),
                L10n.string("message_center.unread_accessibility", count)
            )
        }
        XCTAssertEqual(MessageUnreadBadge.accessibilityValue(for: 0), "")
        XCTAssertTrue(MessageUnreadBadge.accessibilityValue(for: 100).contains("100"))
        XCTAssertFalse(MessageUnreadBadge.accessibilityValue(for: 100).contains("99+"))
    }

    @MainActor
    func testNativeTabBadgeAndMineEntryRenderAcrossCountsAndAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            for typeSize in [DynamicTypeSize.large, .accessibility5] {
                for count in [0, 1, 99, 100] {
                    try render(count: count, scheme: scheme, typeSize: typeSize)
                }
            }
        }
    }

    @MainActor
    private func render(count: Int, scheme: ColorScheme, typeSize: DynamicTypeSize) throws {
        let host = UIHostingController(rootView: MessageUnreadBadgeFixture(count: count)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.horizontalSizeClass, .compact))
        host.traitOverrides.horizontalSizeClass = .compact
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutIfNeeded()

        let tabBar = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UITabBar }.first)
        let items = try XCTUnwrap(tabBar.items)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.last?.badgeValue, MessageUnreadBadge.tabValue(for: count))
        XCTAssertTrue(items.dropLast().allSatisfy { $0.badgeValue == nil })
        let nativeAccessibility = XCTAttachment(string: items.map {
            "title=\($0.title ?? "nil"), label=\($0.accessibilityLabel ?? "nil"), value=\($0.accessibilityValue ?? "nil")"
        }.joined(separator: "\n"))
        nativeAccessibility.name = "unread-native-accessibility-\(count)-\(scheme)-\(typeSize)"
        nativeAccessibility.lifetime = .keepAlways
        add(nativeAccessibility)
        XCTAssertEqual(items.last?.accessibilityValue ?? "", MessageUnreadBadge.accessibilityValue(for: count))
        XCTAssertGreaterThan(tabBar.bounds.width, 0)
        XCTAssertTrue(host.view.bounds.contains(tabBar.convert(tabBar.bounds, to: host.view)))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        // Logic-test runners have no scene; layer rendering still captures mounted native controls.
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "The mounted fixture must contain rendered content")
        let attachment = XCTAttachment(image: image)
        attachment.name = "unread-\(count)-\(scheme)-\(typeSize)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private struct MessageUnreadBadgeFixture: View {
    let count: Int

    var body: some View {
        TabView(selection: .constant(3)) {
            Color.clear
                .tag(0)
                .tabItem { Label(L10n.string("tab.home"), systemImage: "house") }
            Color.clear
                .tag(1)
                .tabItem { Label(L10n.string("tab.forum"), systemImage: "text.bubble") }
            Color.clear
                .tag(2)
                .tabItem { Label(L10n.string("tab.favorites"), systemImage: "heart.text.square") }
            NavigationStack {
                List {
                    MineLibraryEntriesSection(
                        offlineCacheQueueCount: 3,
                        unreadMessageCount: count,
                        showMessages: {},
                        showOfflineCacheQueue: {},
                        showMyLikes: {},
                        showHistory: {}
                    )
                }
                .navigationTitle(L10n.string("tab.mine"))
            }
            .messageUnreadTabAccessibility(count: count)
            .tag(3)
            .tabItem {
                Label(L10n.string("tab.mine"), systemImage: "person.crop.circle")
                    .accessibilityValue(MessageUnreadBadge.accessibilityValue(for: count))
            }
            .badge(MessageUnreadBadge.tabValue(for: count))
        }
    }
}
