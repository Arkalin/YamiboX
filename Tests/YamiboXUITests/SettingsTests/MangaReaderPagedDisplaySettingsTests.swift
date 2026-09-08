import SwiftUI
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class MangaReaderPagedDisplaySettingsTests: XCTestCase {
    @MainActor
    func testPagedDisplayFitsSmallScreensAndLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 480] {
                for typeSize in [DynamicTypeSize.large, .accessibility5] {
                    let view = displayFixture(scheme: scheme, typeSize: typeSize)
                    let size = measuredSize(view, width: width)
                    XCTAssertEqual(size.width, width, accuracy: 0.5)
                    XCTAssertLessThan(size.height, 1_100)
                    try attach(view, width: width, name: "display-\(scheme)-\(Int(width))-\(typeSize)")
                }
            }
        }
    }

    @MainActor
    func testEdgeFillSelectionKeepsStableLayout() throws {
        for scheme in [ColorScheme.light, .dark] {
            let baseline = measuredSize(displayFixture(scheme: scheme), width: 320)
            for fill in MangaPageEdgeFillStyle.allCases {
                let view = displayFixture(scheme: scheme, fill: fill)
                let size = measuredSize(view, width: 320)
                XCTAssertEqual(size.height, baseline.height, accuracy: 0.5)
                try attach(view, width: 320, name: "fill-\(scheme)-\(fill.rawValue)")
            }
        }
    }

    @MainActor
    func testScrollingHidesPagedSettingsAndSpreadHidesOnlyScale() throws {
        let palette = palette(.light)
        for mode in MangaReadingMode.allCases {
            let view = MangaReaderSettingsPagingSection(
                settings: .constant(MangaReaderSettings(readingMode: mode)),
                palette: palette,
                isPadDevice: false,
                usesTwoPageSpread: false
            ).padding(20).background(palette.bodyBackground)
            let height = measuredSize(view, width: 320).height
            if mode == .vertical {
                XCTAssertLessThan(height, 250)
            } else {
                XCTAssertGreaterThan(height, 600)
            }
            try attach(view, width: 320, name: "paging-section-\(mode.rawValue)", expectsSwitch: mode == .paged)
        }
        let single = measuredSize(displayFixture(), width: 320)
        let spread = displayFixture(usesSpread: true)
        XCTAssertGreaterThan(single.height - measuredSize(spread, width: 320).height, 44)
        try attach(spread, width: 320, name: "spread-display")
    }

    @MainActor
    private func displayFixture(
        scheme: ColorScheme = .light,
        typeSize: DynamicTypeSize = .large,
        fill: MangaPageEdgeFillStyle = .black,
        usesSpread: Bool = false
    ) -> some View {
        let palette = palette(scheme)
        return MangaReaderPagedDisplaySettings(
            settings: .constant(MangaReaderSettings(readingMode: .paged, pageEdgeFillStyle: fill)),
            palette: palette,
            usesTwoPageSpread: usesSpread
        )
        .padding(20)
        .background(palette.cardBackground)
        .padding(20)
        .background(palette.bodyBackground)
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, typeSize)
    }

    @MainActor
    private func palette(_ scheme: ColorScheme) -> MangaReaderSettingsPalette {
        MangaReaderSettingsPalette(colorScheme: scheme,
            controlAccent: scheme == .dark ? Color(red: 0.60, green: 0.85, blue: 0.78) : Color(red: 0.12, green: 0.38, blue: 0.32))
    }

    @MainActor
    private func measuredSize(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @MainActor
    private func attach(_ view: some View, width: CGFloat, name: String, expectsSwitch: Bool = true) throws {
        // Native switches need a mounted UIKit hierarchy rather than ImageRenderer.
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let switches = descendants(of: host.view).compactMap { $0 as? UISwitch }
        XCTAssertEqual(switches.count, expectsSwitch ? 1 : 0)
        if let toggle = switches.first {
            XCTAssertTrue(toggle.isOn)
            XCTAssertGreaterThanOrEqual(toggle.bounds.width, 44)
            XCTAssertTrue(host.view.bounds.contains(toggle.convert(toggle.bounds, to: host.view)))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "The mounted snapshot must contain rendered content")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
