import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class NovelReaderQuietThemeTests: XCTestCase {
    func testQuietBackgroundAndGlyphColorsMatchReferenceInBothAppearances() throws {
        let settings = NovelReaderAppearanceSettings(backgroundStyle: .quiet)
        let text = "Title\nBody text"
        let documents = [
            NovelAttributedTextFactory.makeAttributedText(
                text: text, chapterTitle: "Title", settings: settings
            ),
            NovelAttributedTextFactory.makeAttributedText(
                text: text,
                chapterTitleRange: NovelCharacterRange(location: 0, length: 5),
                settings: settings
            )
        ]

        for scheme in [ColorScheme.light, .dark] {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            let background = ResolvedColor(hex: scheme == .dark ? 0x010101 : 0x4A494F)
            let foreground = ResolvedColor(hex: scheme == .dark ? 0x8E8E90 : 0xEBEAF0)
            XCTAssertEqual(ResolvedColor(readerThemeColor(for: .quiet, colorScheme: scheme), style), background)
            XCTAssertEqual(
                ResolvedColor(Color(uiColor: readerThemeUIColor(for: .quiet, colorScheme: scheme)), style),
                background
            )
            for document in documents {
                for offset in [0, 6] {
                    let color = try XCTUnwrap(document.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
                    let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                    XCTAssertEqual(ResolvedColor(Color(uiColor: resolved), style), foreground)
                    XCTAssertEqual(resolved.cgColor.alpha, 1)
                }
            }
            let palette = NovelReaderSheetPalette(settings: settings, colorScheme: scheme, controlAccent: .blue)
            XCTAssertEqual(ResolvedColor(palette.heroText, style), foreground)
            XCTAssertGreaterThan(foreground.contrast(with: background), 4.5)
        }
    }

    @MainActor
    func testPreviewAndLiveTextKitSurfacesRenderQuietGlyphsInBothAppearances() throws {
        let text = String(repeating: "Quiet reading. ", count: 12)
        for mode in ReaderReadingMode.allCases {
            let settings = NovelReaderAppearanceSettings(backgroundStyle: .quiet, readingMode: mode)
            let preview = NovelTextSettingsPreviewSurface(text: text, settings: settings)
            let runtime = NovelTextViewportRuntimeOwner()
            let transaction = try runtime.prepareTransaction(preparedInput: NovelTextLayout.prepareInput(
                document: NovelReaderProjection(
                    threadID: "quiet-theme", view: 1, maxView: 1,
                    segments: [.text(text, chapterTitle: nil)]
                ),
                settings: settings,
                layout: NovelReaderLayout(width: 320, height: 568, readingMode: mode)
            ))
            try runtime.prepareInitialViewport(for: transaction, around: 0)
            XCTAssertTrue(runtime.commit(transaction))
            let reference = try XCTUnwrap(runtime.displayReference(for: NovelReaderSurfaceIdentity(
                generation: transaction.generation, ordinal: 0
            )))

            for style in [UIUserInterfaceStyle.light, .dark, .light] {
                let expected: [UInt8] = style == .dark ? [142, 142, 144] : [235, 234, 240]
                try assertRenderedGlyphColor(style: style, expected: expected) { context, bounds in
                    preview.draw(in: context, bounds: bounds)
                }
                try assertRenderedGlyphColor(style: style, expected: expected) { context, bounds in
                    reference.drawText(in: context, bounds: bounds)
                }
            }
        }
    }

    @MainActor
    func testThemePickerFitsNarrowAndWideLayoutsWithLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            let palette = NovelReaderSheetPalette(
                settings: NovelReaderAppearanceSettings(backgroundStyle: .quiet),
                colorScheme: scheme,
                controlAccent: .blue
            )
            for width in [CGFloat(240), 313, 600] {
                for typeSize in [DynamicTypeSize.large, .accessibility3] {
                    let view = NovelReaderThemePicker(
                        selectedStyle: .quiet, colorScheme: scheme, palette: palette, onSelect: { _ in }
                    )
                    .environment(\.dynamicTypeSize, typeSize)
                    let size = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2_000))
                    XCTAssertEqual(size.width, width, accuracy: 0.5)
                    XCTAssertGreaterThan(size.height, 44)
                    XCTAssertLessThan(size.height, 800)
                }
            }
        }
    }

    private func assertRenderedGlyphColor(
        style: UIUserInterfaceStyle,
        expected: [UInt8],
        draw: (CGContext, CGRect) -> Void
    ) throws {
        let width = 320
        let height = 568
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                UIGraphicsPushContext(context)
                defer { UIGraphicsPopContext() }
                draw(context, CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        var opaqueGlyphPixels = 0
        var maximumChannelError = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
            opaqueGlyphPixels += 1
            for channel in 0..<3 {
                maximumChannelError = max(maximumChannelError, abs(Int(pixels[offset + channel]) - Int(expected[channel])))
            }
        }
        XCTAssertGreaterThan(opaqueGlyphPixels, 100)
        XCTAssertLessThanOrEqual(maximumChannelError, 2)
    }
}
