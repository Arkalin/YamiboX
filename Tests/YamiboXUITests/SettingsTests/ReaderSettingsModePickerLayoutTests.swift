import SwiftUI
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class ReaderSettingsModePickerLayoutTests: XCTestCase {
    @MainActor
    func testDirectionMatchesModeControlAcrossPalettesAndTextSizes() throws {
        for reader in Reader.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(320), 480] {
                    for typeSize in [DynamicTypeSize.large, .accessibility5] {
                        let view = fixture(reader: reader, scheme: scheme, typeSize: typeSize, includesDirection: true)
                        let size = measuredSize(view, width: width)
                        XCTAssertEqual(size.width, width, accuracy: 0.5)
                        XCTAssertLessThan(size.height, 1_100)
                        try attach(view, width: width,
                            name: "direction-\(reader.rawValue)-\(scheme)-\(Int(width))-\(typeSize)")
                    }
                }
            }
        }
    }

    @MainActor
    func testPagedLayoutFitsPhoneAndSplitViewWithBothPalettes() throws {
        for reader in Reader.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(320), 480] {
                    for typeSize in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                        let view = fixture(
                            reader: reader,
                            scheme: scheme,
                            typeSize: typeSize,
                            mode: .paged,
                            style: .quickFade
                        )
                        let size = measuredSize(view, width: width)
                        XCTAssertEqual(size.width, width, accuracy: 0.5)
                        XCTAssertGreaterThanOrEqual(size.height, 4 * 44 + 44)
                        // Even at the largest text size, icons must leave room for words.
                        XCTAssertLessThan(size.height, 900)
                        try attach(
                            view,
                            width: width,
                            name: "\(reader.rawValue)-\(scheme)-\(Int(width))-\(typeSize)-paged"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    func testScrollRemovesAnimationRowsWithoutReservingTheirHeight() throws {
        for reader in Reader.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let paged = fixture(reader: reader, scheme: scheme, mode: .paged)
                let scroll = fixture(reader: reader, scheme: scheme, mode: .scroll)
                let pagedSize = measuredSize(paged, width: 320)
                let scrollSize = measuredSize(scroll, width: 320)
                XCTAssertEqual(scrollSize.width, pagedSize.width, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(pagedSize.height - scrollSize.height, 4 * 44)
                try attach(scroll, width: 320, name: "\(reader.rawValue)-\(scheme)-320-scroll")
            }
        }
    }

    @MainActor
    func testAnimationSelectionKeepsStableLayoutAndLargeTypeCanGrow() throws {
        for reader in Reader.allCases {
            let baseSize = measuredSize(fixture(reader: reader), width: 320)
            for style in ReaderPagedTurnStyle.allCases {
                let view = fixture(reader: reader, style: style)
                let size = measuredSize(view, width: 320)
                XCTAssertEqual(size.width, baseSize.width, accuracy: 0.5)
                XCTAssertEqual(size.height, baseSize.height, accuracy: 0.5)
                try attach(view, width: 320, name: "\(reader.rawValue)-selection-\(style.rawValue)")
            }
            let largeSize = measuredSize(
                fixture(reader: reader, typeSize: .accessibility3),
                width: 320
            )
            XCTAssertGreaterThan(largeSize.height, baseSize.height)
        }
    }

    private enum Reader: String, CaseIterable {
        case novel
        case manga
    }

    @MainActor
    @ViewBuilder
    private func fixture(
        reader: Reader,
        scheme: ColorScheme = .light,
        typeSize: DynamicTypeSize = .large,
        mode: ReaderSettingsReadingModeOption = .paged,
        style: ReaderPagedTurnStyle = .none,
        includesDirection: Bool = false
    ) -> some View {
        let accent = scheme == .dark ? Color(red: 0.60, green: 0.85, blue: 0.78) : Color(red: 0.12, green: 0.38, blue: 0.32)
        switch reader {
        case .novel:
            let palette = NovelReaderSheetPalette(
                settings: NovelReaderAppearanceSettings(),
                colorScheme: scheme,
                controlAccent: accent
            )
            section(palette: palette, mode: mode, style: style, reader: reader, includesDirection: includesDirection)
                .background(palette.bodyBackground)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
        case .manga:
            let palette = MangaReaderSettingsPalette(colorScheme: scheme, controlAccent: accent)
            section(palette: palette, mode: mode, style: style, reader: reader, includesDirection: includesDirection)
                .background(palette.bodyBackground)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, typeSize)
        }
    }

    @MainActor
    private func section(
        palette: some ReaderSettingsPalette,
        mode: ReaderSettingsReadingModeOption,
        style: ReaderPagedTurnStyle,
        reader: Reader,
        includesDirection: Bool
    ) -> some View {
        ReaderSettingsSection(title: L10n.string("reader.section.display"), palette: palette) {
            ReaderSettingsModePicker(
                selection: mode,
                pagedTurnStyle: style,
                palette: palette,
                onSelect: { _ in },
                onSelectAnimation: { _ in }
            )
            if includesDirection {
                ReaderSettingsDivider(palette: palette)
                switch reader {
                case .novel:
                    ReaderSettingsDirectionPicker(
                        title: L10n.string("reader.page_turn_direction"),
                        selection: ReaderPageTurnDirection.leftToRight,
                        palette: palette,
                        onSelect: { _ in }
                    )
                case .manga:
                    ReaderSettingsDirectionPicker(
                        title: L10n.string("manga.page_turn_direction"),
                        selection: MangaPageTurnDirection.rightToLeft,
                        palette: palette,
                        onSelect: { _ in }
                    )
                }
            }
        }
        .padding(20)
    }

    @MainActor
    private func measuredSize(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @MainActor
    private func attach(_ view: some View, width: CGFloat, name: String) throws {
        // ImageRenderer also works in the logic-test runner, without an app scene.
        let renderer = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 44)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
