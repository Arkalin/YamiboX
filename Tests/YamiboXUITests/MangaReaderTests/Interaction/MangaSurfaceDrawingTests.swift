#if os(iOS)
import UIKit
import Testing
@testable import YamiboXUI

@MainActor @Suite("Paged production drawing")
struct MangaSurfaceDrawingTests {
    @Test(arguments: [CGFloat(400), 600, 800, 1200], [CGFloat(0), 0.5, 1])
    func centralOverlayStaysInViewport(width: CGFloat, progress: CGFloat) async throws {
        let context = try #require(CGContext(data: nil, width: Int(width), height: 800, bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 800))
        let bitmap = try #require(context.makeImage())
        let runtime = MangaSurfaceRuntime()
        let view = MangaNativeSurfaceView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let image = UIImageView(image: UIImage(cgImage: bitmap))
        view.zoomContentView.addSubview(image)
        view.onBaseSizeChange = { image.frame = CGRect(origin: .zero, size: $0) }
        view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(),
            geometry: .image(size: CGSize(width: width, height: 800), viewport: view.bounds.size,
                fit: .fitHeight, alignment: .left), imageLoaded: true)
        view.layoutIfNeeded()
        view.setContentOffset(CGPoint(x: (width - 400) * progress, y: 0), animated: false)
        try await Task.sleep(for: .milliseconds(20))
        let overlay = UIView(frame: runtime.menuFrame.offsetBy(dx: view.bounds.minX, dy: view.bounds.minY))
        overlay.backgroundColor = .red
        view.addSubview(overlay)
        let host = UIView(frame: view.frame)
        host.addSubview(view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = try #require(UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            host.layer.render(in: context.cgContext)
        }.cgImage)
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
        view.detach()
    }
}
#endif
