import ImageIO
import SwiftUI
import UIKit

/// Animated image bytes — GIF, APNG, animated WebP/HEICS — in the two shapes
/// the app needs them: a cheap "is this an animation at all?" test for the
/// decoding path, and a frame stream for the rendering path.
enum YamiboAnimatedImage {
    /// Where one animated container keeps its per-frame timing.
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

    /// Whether `data` holds an animation worth playing. Only container
    /// metadata is read — no frame is decoded — so the decoding path can ask
    /// this of every image it sees.
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

    /// The declared on-screen duration of one frame, in seconds, or `nil` when
    /// the frame carries no animation timing.
    private static func frameDelay(in source: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return nil
        }
        for keys in frameTimingKeys {
            guard let container = properties[keys.container] as? [CFString: Any] else { continue }
            // The unclamped value is the file's own timing; the clamped one is
            // ImageIO's floor for it. Either proves the frame is animated.
            if let unclamped = container[keys.unclampedDelay] as? Double {
                return unclamped
            }
            if let delay = container[keys.delay] as? Double {
                return delay
            }
        }
        return nil
    }

    /// Bridges `CGAnimateImageDataWithBlock` — which pushes decoded frames on
    /// the main queue until its callback asks it to stop — into a stream a
    /// SwiftUI `.task` can consume and cancel like any other async sequence.
    ///
    /// ImageIO owns both the decoding and the frame clock, so a hundred-frame
    /// GIF costs one frame of memory rather than a hundred, and per-frame
    /// delays and loop counts come out right without a timer of our own.
    static func frames(of data: Data, scale: CGFloat) -> AsyncStream<UIImage> {
        // Only the newest frame matters: a consumer that falls behind should
        // skip ahead rather than replay a backlog in fast-forward.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let playback = Playback()
            continuation.onTermination = { _ in
                // The consumer is gone (view dismissed, task cancelled), but
                // ImageIO only takes the hint from inside its own callback, so
                // playback really ends on the next frame tick.
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
            // Still images and unreadable bytes never animate; the caller keeps
            // showing its poster frame.
            if status != noErr {
                continuation.finish()
            }
        }
    }

    /// The stop flag shared between the consumer (any thread) and ImageIO's
    /// main-queue callback.
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

/// Plays animated image bytes into the caller's image content, one frame at a
/// time, and falls back to the still poster frame whenever playback is off.
struct YamiboAnimatedImageView<Content: View>: View {
    /// Identifies the payload, so a view recycled onto a different image
    /// restarts playback instead of finishing the previous animation.
    let identity: String
    let data: Data
    /// Shown until the first frame arrives and whenever playback is paused. It
    /// also fixes the scale every frame is built with, so a still image and
    /// its animated form always lay out identically.
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

    /// A backgrounded app renders nothing, so leaving ImageIO decoding frames
    /// for it would be pure battery cost — and a reader who turned off
    /// Auto-Play Animated Images asked for the still frame everywhere.
    private var isPlaybackActive: Bool {
        scenePhase == .active && playsAnimatedImages
    }
}
