import SwiftUI
import Testing
@testable import YamiboXUI

@MainActor @Suite("Paged production drawing")
struct MangaSurfaceDrawingTests {
    @Test(arguments: [CGFloat(400), 600, 800, 1200], [CGFloat(0), 0.5, 1])
    func centralOverlayStaysInViewport(width: CGFloat, progress: CGFloat) throws {
        let context = try #require(CGContext(data: nil, width: Int(width), height: 800, bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 800))
        let bitmap = try #require(context.makeImage())
        let layout = MangaPagedImageSurfaceLayout(imageSize: CGSize(width: width, height: 800),
            containerSize: CGSize(width: 400, height: 800), fitMode: .fitHeight,
            initialHorizontalAlignment: .left, zoomScale: 1)
        let offset = CGSize(width: -(width - 400) * progress, height: 0)
        let frame = MangaPageLongPressHitTesting.allowedFrame(in: CGRect(origin: .zero, size: layout.containerSize),
            imageFrame: layout.displayedImageFrame(forUserOffset: offset))
        let drawing = MangaSurfaceDrawing(image: Image(decorative: bitmap, scale: 1), background: .black, layout: layout, offset: offset)
            .overlay {
                Color(red: 1, green: 0, blue: 0).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
            }
        let renderer = ImageRenderer(content: drawing)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == 400)
        #expect(rendered.height == 800)
        let sample = try #require(CGContext(data: nil, width: 400, height: 800, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(rendered, in: CGRect(x: 0, y: 0, width: 400, height: 800))
        let bytes = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        let redXs = (0..<400).filter { x in
            let i = 400 * 1600 + x * 4
            return bytes[i] > 200 && bytes[i + 1] < 40 && bytes[i + 2] < 40
        }
        #expect(abs(try #require(redXs.first) - 133) <= 1)
        #expect(abs(try #require(redXs.last) - 266) <= 1)
    }
}
