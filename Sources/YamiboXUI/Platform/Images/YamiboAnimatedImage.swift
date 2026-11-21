import ImageIO
import SwiftUI
import UIKit

enum YamiboAnimatedImage {
    private struct FrameTimingKeys {
        var container: CFString
        var delay: CFString
        var unclampedDelay: CFString
    }

    /// One entry per animated container ImageIO reads. A multi-frame file
    /// carrying none of them — a multi-size `.ico`, a multi-page TIFF — holds
    /// alternates of one still image, not animation. Computed rather than
    /// stored because `CFString` constants are not `Sendable`.
    private static var frameTimingKeys: [FrameTimingKeys] {
        [
            FrameTimingKeys(
                container: kCGImagePropertyGIFDictionary,
                delay: kCGImagePropertyGIFDelayTime,
                unclampedDelay: kCGImagePropertyGIFUnclampedDelayTime
            ),
            FrameTimingKeys(
                container: kCGImagePropertyPNGDictionary,
                delay: kCGImagePropertyAPNGDelayTime,
                unclampedDelay: kCGImagePropertyAPNGUnclampedDelayTime
            ),
            FrameTimingKeys(
                container: kCGImagePropertyWebPDictionary,
                delay: kCGImagePropertyWebPDelayTime,
                unclampedDelay: kCGImagePropertyWebPUnclampedDelayTime
            ),
            FrameTimingKeys(
                container: kCGImagePropertyHEICSDictionary,
                delay: kCGImagePropertyHEICSDelayTime,
                unclampedDelay: kCGImagePropertyHEICSUnclampedDelayTime
            )
        ]
    }

    static func isAnimated(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) > 1 else {
            return false
        }
        return frameDelay(in: source, at: 0) != nil
    }

    private static func frameDelay(in source: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return nil
        }
        for keys in frameTimingKeys {
            guard let container = properties[keys.container] as? [CFString: Any] else { continue }
            if let unclamped = container[keys.unclampedDelay] as? Double {
                return unclamped
            }
            if let delay = container[keys.delay] as? Double {
                return delay
            }
        }
        return nil
    }

    static func frames(of data: Data, scale: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let playback = Playback()
            continuation.onTermination = { _ in
                playback.stop()
            }
            let status = CGAnimateImageDataWithBlock(data as CFData, nil) { _, frame, stop in
                guard !playback.isStopped else {
                    stop.pointee = true
                    continuation.finish()
                    return
                }
                continuation.yield(UIImage(cgImage: frame, scale: scale, orientation: .up))
            }
            if status != noErr {
                continuation.finish()
            }
        }
    }

    private final class Playback: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.withLock { stopped }
        }

        func stop() {
            lock.withLock { stopped = true }
        }
    }
}

struct YamiboAnimatedImageView<Content: View>: View {
    let identity: String
    let data: Data
    let posterImage: UIImage
    let content: (Image) -> Content

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @State private var frame: UIImage?

    var body: some View {
        content(Image(uiImage: frame ?? posterImage))
            .task(id: playbackIdentity) {
                frame = nil
                guard isPlaybackActive else { return }
                for await frame in YamiboAnimatedImage.frames(of: data, scale: posterImage.scale) {
                    self.frame = frame
                }
            }
    }

    private var playbackIdentity: String {
        "\(identity)#\(isPlaybackActive)"
    }

    private var isPlaybackActive: Bool {
        scenePhase == .active && playsAnimatedImages
    }
}
