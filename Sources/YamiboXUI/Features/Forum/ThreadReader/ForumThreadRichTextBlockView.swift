import SwiftUI
import UIKit
import YamiboXCore

/// A single selectable text container handles authored paragraph metrics and
/// ruby. TextKit lays out the base text; annotations never become unbreakable
/// SwiftUI subviews or replacement characters in copied text.
struct ForumThreadRichTextBlockView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.yamiboImagePipeline) private var pipeline
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 28
    @State private var images: [URL: UIImage] = [:]

    let block: ForumThreadTextBlock
    let refererURL: URL
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumThreadNativeTextView(
            block: block, theme: theme, images: images, imageSize: imageSize,
            dynamicTypeSize: dynamicTypeSize, onURLTap: onURLTap
        )
        .frame(maxWidth: .infinity, alignment: block.alignment.swiftUIFrameAlignment)
        .task(id: requestIdentity) {
            images = [:]
            guard let pipeline else { return }
            await withTaskGroup(of: Void.self) { group in
                for url in requestIdentity.urls {
                    group.addTask { await load(url, pipeline: pipeline) }
                }
            }
        }
    }

    private struct RequestIdentity: Hashable {
        let urls: [URL]
        let refererURL: URL
        let pipelineID: ObjectIdentifier?
        let animates: Bool
    }

    private var requestIdentity: RequestIdentity {
        RequestIdentity(urls: Array(Set(block.inlineImages.map(\.image.url))).sorted { $0.absoluteString < $1.absoluteString },
                        refererURL: refererURL, pipelineID: pipeline.map(ObjectIdentifier.init),
                        animates: scenePhase == .active && playsAnimatedImages)
    }

    @MainActor
    private func load(_ url: URL, pipeline: YamiboUIImagePipeline) async {
        do {
            let loaded = try await pipeline.displayImage(for: YamiboImageSource(url: url, refererPageURL: refererURL))
            guard !Task.isCancelled else { return }
            images[url] = loaded.image
            guard requestIdentity.animates, let data = loaded.animatedData else { return }
            for await frame in YamiboAnimatedImage.frames(of: data, scale: loaded.image.scale) {
                guard !Task.isCancelled else { return }
                images[url] = frame
            }
        } catch {
            guard !Task.isCancelled else { return }
            images[url] = UIImage(systemName: "photo")
        }
    }
}

extension NSAttributedString.Key {
    static let forumRuby = NSAttributedString.Key("yamibo.forum.ruby")
}

final class ForumThreadInlineAttachment: NSTextAttachment {
    var sourceURL: URL?
}

final class ForumThreadRubyAnnotation: NSObject {
    let text: String
    let range: NSRange

    init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ForumThreadRubyAnnotation else { return false }
        return text == other.text && range == other.range
    }

    override var hash: Int { text.hashValue ^ range.location ^ range.length }
}

private struct ForumThreadNativeTextView: UIViewRepresentable {
    let block: ForumThreadTextBlock
    let theme: ForumTheme
    let images: [URL: UIImage]
    let imageSize: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let onURLTap: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onURLTap: onURLTap) }

    func makeUIView(context: Context) -> UITextView {
        // This explicit TextKit 1 stack supplies glyph geometry for ruby while
        // preserving UIKit selection, links, accessibility and paragraph layout.
        let storage = NSTextStorage()
        let layout = ForumThreadRubyLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = UITextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.linkTextAttributes = [:]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onURLTap = onURLTap
        if let layout = view.layoutManager as? ForumThreadRubyLayoutManager {
            layout.annotationColor = UIColor(theme.secondaryText)
        }
        let inset = block.rubies.isEmpty ? 0 : UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 2
        let insets = UIEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        if view.textContainerInset != insets { view.textContainerInset = insets }
        let coordinator = context.coordinator
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        if coordinator.block != block || coordinator.themeID != theme.id
            || coordinator.dynamicTypeSize != dynamicTypeSize || coordinator.pointSize != pointSize
            || coordinator.imageSize != imageSize {
            let text = ForumThreadTextBlockFormatter(block: block, theme: theme).nativeText(images: images, imageSize: imageSize)
            let selection = view.selectedRange
            view.attributedText = text
            if NSMaxRange(selection) <= text.length { view.selectedRange = selection }
            coordinator.block = block
            coordinator.themeID = theme.id
            coordinator.dynamicTypeSize = dynamicTypeSize
            coordinator.pointSize = pointSize
            coordinator.imageSize = imageSize
            coordinator.images = images
            coordinator.attachments = [:]
            // Capture TextKit's actual attachment instances once. Frame changes
            // mutate only their images, never the selectable text or its metrics.
            view.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let attachment = value as? ForumThreadInlineAttachment,
                      let url = attachment.sourceURL else { return }
                coordinator.attachments[url, default: []].append((attachment, range))
            }
            view.invalidateIntrinsicContentSize()
        } else {
            for (url, attachments) in coordinator.attachments where coordinator.images[url] !== images[url] {
                let source = images[url] ?? UIImage(systemName: "face.smiling") ?? UIImage()
                let image = ForumThreadInlineTextView.sizedUIImage(source, dimension: imageSize)
                for (attachment, range) in attachments {
                    attachment.image = image
                    view.layoutManager.invalidateDisplay(forCharacterRange: range)
                }
            }
            coordinator.images = images
        }
        view.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onURLTap: (URL) -> Void
        var block: ForumThreadTextBlock?
        var themeID: String?
        var dynamicTypeSize: DynamicTypeSize?
        var pointSize: CGFloat?
        var imageSize: CGFloat?
        var images: [URL: UIImage] = [:]
        var attachments: [URL: [(NSTextAttachment, NSRange)]] = [:]
        init(onURLTap: @escaping (URL) -> Void) { self.onURLTap = onURLTap }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.onURLTap(url) }
        }
    }
}

private final class ForumThreadRubyLayoutManager: NSLayoutManager {
    var annotationColor: UIColor = .secondaryLabel

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.forumRuby, in: characters) { value, _, _ in
            guard let annotation = value as? ForumThreadRubyAnnotation else { return }
            let glyphs = self.glyphRange(forCharacterRange: annotation.range, actualCharacterRange: nil)
            let visibleGlyphs = NSIntersectionRange(glyphs, glyphsToShow)
            guard visibleGlyphs.length > 0 else { return }
            self.enumerateLineFragments(forGlyphRange: visibleGlyphs) { line, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let partCharacters = self.characterRange(forGlyphRange: part, actualGlyphRange: nil)
                let reading = Array(annotation.text)
                let start = max(0, partCharacters.location - annotation.range.location) * reading.count / max(annotation.range.length, 1)
                let end = min(annotation.range.length, NSMaxRange(partCharacters) - annotation.range.location) * reading.count / max(annotation.range.length, 1)
                guard start < end, end <= reading.count else { return }
                let text = String(reading[start ..< end]) as NSString
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let font = storage.attribute(.font, at: partCharacters.location, effectiveRange: nil) as? UIFont ?? .preferredFont(forTextStyle: .body)
                let preferred = UIFont.preferredFont(forTextStyle: .caption2)
                let naturalWidth = text.size(withAttributes: [.font: preferred]).width
                let annotationFont = preferred.withSize(preferred.pointSize * min(1, bounds.width / max(naturalWidth, 1)))
                let width = text.size(withAttributes: [.font: annotationFont]).width
                let baseline = line.minY + self.location(forGlyphAt: part.location).y
                text.draw(at: CGPoint(x: origin.x + bounds.midX - width / 2,
                                      y: origin.y + baseline - font.ascender - annotationFont.lineHeight),
                          withAttributes: [.font: annotationFont, .foregroundColor: self.annotationColor])
            }
        }
    }
}
