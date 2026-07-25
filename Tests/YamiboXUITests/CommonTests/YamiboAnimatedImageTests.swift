import CoreGraphics
import ImageIO
import Nuke
import Testing
import UniformTypeIdentifiers
@testable import YamiboXUI

#if os(iOS)
@Suite("CommonTests: Animated Image")
struct YamiboAnimatedImageTests {
    /// Nuke's own decoder keeps the bytes of a GIF but of nothing else, so the
    /// wrapper is what makes every other animated format playable.
    @Test func decoderKeepsBytesOfEveryAnimatedFormat() throws {
        let decoder = YamiboAnimatedDataPreservingDecoder(base: ImageDecoders.Default())

        let gif = try decoder.decode(try AnimatedImageFixture.gif(frameCount: 4, delay: 0.05))
        let apng = try decoder.decode(try AnimatedImageFixture.apng(frameCount: 4, delay: 0.05))

        #expect(gif.data != nil)
        #expect(apng.data != nil)
    }

    /// Most forum smileys are single-frame GIFs. Nuke's default decoder keeps
    /// their bytes anyway, which would start a player — and hold the bytes in
    /// the image cache — for every one of them.
    @Test func decoderKeepsNoBytesOfStillImages() throws {
        let decoder = YamiboAnimatedDataPreservingDecoder(base: ImageDecoders.Default())

        let png = try decoder.decode(try AnimatedImageFixture.png())
        let gif = try decoder.decode(try AnimatedImageFixture.gif(frameCount: 1, delay: 0.05))

        #expect(png.data == nil)
        #expect(gif.data == nil)
    }

    @Test func multiFrameGIFIsAnimated() throws {
        let gif = try AnimatedImageFixture.gif(frameCount: 4, delay: 0.05)

        #expect(YamiboAnimatedImage.isAnimated(gif))
    }

    @Test func multiFrameAPNGIsAnimated() throws {
        let apng = try AnimatedImageFixture.apng(frameCount: 4, delay: 0.05)

        #expect(YamiboAnimatedImage.isAnimated(apng))
    }

    /// Forum smileys are mostly single-frame GIFs; treating them as animations
    /// would start a player for every one of them.
    @Test func singleFrameImagesAreNotAnimated() throws {
        let gif = try AnimatedImageFixture.gif(frameCount: 1, delay: 0.05)
        let png = try AnimatedImageFixture.png()

        #expect(!YamiboAnimatedImage.isAnimated(gif))
        #expect(!YamiboAnimatedImage.isAnimated(png))
    }

    @Test func emptyAndCorruptBytesAreNotAnimated() {
        #expect(!YamiboAnimatedImage.isAnimated(Data()))
        #expect(!YamiboAnimatedImage.isAnimated(Data("not an image".utf8)))
    }

    @Test func framesStreamReplaysEveryFrameInOrder() async throws {
        let gif = try AnimatedImageFixture.gif(frameCount: 3, delay: 0.02)

        var sizes: [CGSize] = []
        for await frame in YamiboAnimatedImage.frames(of: gif, scale: 2) {
            sizes.append(frame.size)
            // The GIF loops forever; stop once it has proven it plays past its
            // own frame count.
            if sizes.count == 5 { break }
        }

        #expect(sizes.count == 5)
        // Scale divides the pixel size: an 8pt-square fixture at scale 2.
        #expect(sizes.allSatisfy { $0 == CGSize(width: 4, height: 4) })
    }

    @Test func framesStreamEndsForStillImages() async throws {
        let png = try AnimatedImageFixture.png()

        var frameCount = 0
        for await _ in YamiboAnimatedImage.frames(of: png, scale: 1) {
            frameCount += 1
        }

        #expect(frameCount == 0)
    }
}

private enum AnimatedImageFixture {
    struct EncodingFailure: Error {}

    static func gif(frameCount: Int, delay: Double) throws -> Data {
        try encode(
            type: .gif,
            frameCount: frameCount,
            frameProperties: [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary
        )
    }

    static func apng(frameCount: Int, delay: Double) throws -> Data {
        try encode(
            type: .png,
            frameCount: frameCount,
            frameProperties: [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]
            ] as CFDictionary
        )
    }

    static func png() throws -> Data {
        try encode(type: .png, frameCount: 1, frameProperties: nil)
    }

    private static func encode(type: UTType, frameCount: Int, frameProperties: CFDictionary?) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            type.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw EncodingFailure()
        }
        for index in 0 ..< frameCount {
            CGImageDestinationAddImage(destination, try frame(index: index), frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw EncodingFailure()
        }
        return buffer as Data
    }

    private static func frame(index: Int, side: Int = 8) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EncodingFailure()
        }
        // Distinct per-frame fills keep the encoder from collapsing the frames.
        context.setFillColor(gray: CGFloat(index % 8) / 8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else {
            throw EncodingFailure()
        }
        return image
    }
}
#endif
