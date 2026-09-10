import SwiftUI
import UIKit
import YamiboXCore

enum ForumThreadItalicKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "yamibo.forum.italic"
}

enum ForumThreadInlineImageKey: AttributedStringKey {
    typealias Value = ForumThreadImageBlock
    static let name = "yamibo.forum.inline-image"
}

struct ForumThreadItalicAttribute: TextAttribute {}

struct ForumThreadTextRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var runContext = context
                if run[ForumThreadItalicAttribute.self] != nil {
                    let bounds = run.typographicBounds
                    let baseline = bounds.rect.maxY - bounds.descent
                    runContext.concatenate(Self.italicTransform(baseline: baseline))
                }
                runContext.draw(run)
            }
        }
    }

    static func italicTransform(baseline: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: baseline * 0.2, ty: 0)
    }

    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8) }
}

/// One Text keeps native line breaking and selection across text and smileys.
/// Only image frames change during playback; attachment dimensions stay fixed.
struct ForumThreadInlineTextView: View {
    let attributedText: AttributedString
    let refererURL: URL

    @Environment(\.yamiboImagePipeline) private var pipeline
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 28
    @State private var images: [URL: Image] = [:]

    var body: some View {
        Self.composedText(attributedText, images: images, imageSize: imageSize)
            .textRenderer(ForumThreadTextRenderer())
            .task(id: requestIdentity) {
                images = [:]
                guard let pipeline else { return }
                await withTaskGroup(of: Void.self) { group in
                    for url in imageURLs {
                        group.addTask {
                            await load(url, pipeline: pipeline)
                        }
                    }
                }
            }
    }

    static func composedText(_ attributed: AttributedString, images: [URL: Image], imageSize: CGFloat) -> Text {
        attributed.runs.reduce(Text(verbatim: "")) { result, run in
            let part: Text
            if let inline = run[ForumThreadInlineImageKey.self] {
                let image = images[inline.url] ?? sizedImage(UIImage(systemName: "face.smiling") ?? UIImage(), dimension: imageSize)
                let attachment = Text(image)
                    .accessibilityLabel(Text(verbatim: inline.altText ?? L10n.string("forum.thread.image")))
                    .baselineOffset(-imageSize / 7)
                // Adjacent identical smileys coalesce into one attributed run.
                part = attributed[run.range].characters.reduce(Text(verbatim: "")) { text, _ in
                    Text("\(text)\(attachment)")
                }
            } else {
                let text = Text(AttributedString(attributed[run.range]))
                part = run[ForumThreadItalicKey.self] == true ? text.customAttribute(ForumThreadItalicAttribute()) : text
            }
            return Text("\(result)\(part)")
        }
    }

    static func sizedImage(_ image: UIImage, dimension: CGFloat) -> Image {
        let size = CGSize(width: dimension, height: dimension)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            let ratio = min(dimension / max(image.size.width, 1), dimension / max(image.size.height, 1))
            let width = image.size.width * ratio
            let height = image.size.height * ratio
            image.draw(in: CGRect(x: (dimension - width) / 2, y: (dimension - height) / 2, width: width, height: height))
        }
        return Image(uiImage: rendered)
    }

    private var imageURLs: [URL] {
        Array(Set(attributedText.runs.compactMap { $0[ForumThreadInlineImageKey.self]?.url }))
            .sorted { $0.absoluteString < $1.absoluteString }
    }

    private struct RequestIdentity: Hashable {
        let urls: [URL]
        let refererURL: URL
        let pipelineID: ObjectIdentifier?
        let imageSize: CGFloat
        let animates: Bool
    }

    private var requestIdentity: RequestIdentity {
        RequestIdentity(
            urls: imageURLs,
            refererURL: refererURL,
            pipelineID: pipeline.map(ObjectIdentifier.init),
            imageSize: imageSize,
            animates: scenePhase == .active && playsAnimatedImages
        )
    }

    @MainActor
    private func load(_ url: URL, pipeline: YamiboUIImagePipeline) async {
        do {
            let source = YamiboImageSource(url: url, refererPageURL: refererURL)
            let loaded = try await pipeline.displayImage(for: source)
            guard !Task.isCancelled else { return }
            images[url] = Self.sizedImage(loaded.image, dimension: imageSize)
            guard requestIdentity.animates, let data = loaded.animatedData else { return }
            for await frame in YamiboAnimatedImage.frames(of: data, scale: loaded.image.scale) {
                guard !Task.isCancelled else { return }
                images[url] = Self.sizedImage(frame, dimension: imageSize)
            }
        } catch {
            guard !Task.isCancelled else { return }
            images[url] = Self.sizedImage(UIImage(systemName: "photo") ?? UIImage(), dimension: imageSize)
        }
    }
}
