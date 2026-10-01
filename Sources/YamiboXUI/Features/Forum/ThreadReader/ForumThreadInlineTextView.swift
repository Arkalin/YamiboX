import SwiftUI
import UIKit
import YamiboXCore

enum ForumThreadItalicKey: AttributedStringKey {
    typealias Value = Bool
    static let name = "yamibo.forum.italic"
}

enum ForumThreadBaselineOffsetKey: AttributedStringKey {
    typealias Value = Double
    static let name = "yamibo.forum.baseline-offset"
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
    // The custom per-run renderer stops painting sufficiently tall Text views.
    // Before text blocks were kept intact, it only ever drew at most 320 characters.
    private static let maxSyntheticItalicCharacters = 320

    let refererURL: URL
    private let preparedRuns: [PreparedRun]
    private let imageURLs: [URL]
    private let useSyntheticItalics: Bool

    private enum PreparedRun {
        case text(Text)
        case image(ForumThreadImageBlock, count: Int)
    }

    init(attributedText: AttributedString, refererURL: URL) {
        self.refererURL = refererURL
        let syntheticItalics = attributedText.characters.count <= Self.maxSyntheticItalicCharacters
            && attributedText.runs.contains(where: { $0[ForumThreadItalicKey.self] == true })
        useSyntheticItalics = syntheticItalics
        var urls: Set<URL> = []
        // Rebuilt with the input value, not image playback state. Static text
        // slices and modifiers must not be reconstructed for every GIF frame.
        preparedRuns = attributedText.runs.map { run in
            if let inline = run[ForumThreadInlineImageKey.self] {
                urls.insert(inline.url)
                return .image(inline, count: attributedText[run.range].characters.count)
            }
            let text = Text(AttributedString(attributedText[run.range]))
                .baselineOffset(run[ForumThreadBaselineOffsetKey.self] ?? 0)
            if run[ForumThreadItalicKey.self] == true {
                return .text(syntheticItalics ? text.customAttribute(ForumThreadItalicAttribute()) : text.italic())
            }
            return .text(text)
        }
        imageURLs = urls.sorted { $0.absoluteString < $1.absoluteString }
    }

    @Environment(\.yamiboImagePipeline) private var pipeline
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 28
    @State private var images: [URL: Image] = [:]

    var body: some View {
        let text = composedText()
        Group {
            if useSyntheticItalics {
                text.textRenderer(ForumThreadTextRenderer())
            } else {
                text
            }
        }
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

    private func composedText() -> Text {
        preparedRuns.reduce(Text(verbatim: "")) { result, run in
            let part: Text
            switch run {
            case let .image(inline, count):
                let image = images[inline.url] ?? Self.sizedImage(UIImage(systemName: "face.smiling") ?? UIImage(), dimension: imageSize)
                let attachment = Text(image)
                    .accessibilityLabel(Text(verbatim: inline.altText ?? L10n.string("forum.thread.image")))
                    .baselineOffset(-imageSize / 7)
                // Adjacent identical smileys coalesce into one attributed run.
                part = (0..<count).reduce(Text(verbatim: "")) { text, _ in
                    Text("\(text)\(attachment)")
                }
            case let .text(text):
                part = text
            }
            return Text("\(result)\(part)")
        }
    }

    static func sizedImage(_ image: UIImage, dimension: CGFloat) -> Image {
        Image(uiImage: sizedUIImage(image, dimension: dimension))
    }

    static func sizedUIImage(_ image: UIImage, dimension: CGFloat) -> UIImage {
        let size = CGSize(width: dimension, height: dimension)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            let ratio = min(dimension / max(image.size.width, 1), dimension / max(image.size.height, 1))
            let width = image.size.width * ratio
            let height = image.size.height * ratio
            image.draw(in: CGRect(x: (dimension - width) / 2, y: (dimension - height) / 2, width: width, height: height))
        }
        return rendered
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
