import SwiftUI
import UIKit
import YamiboXCore

@MainActor
enum ForumBBCodeTextCodec {
    static func attributedText(session: ForumBBCodeSession) -> NSAttributedString {
        if !session.isVisual {
            return NSAttributedString(string: session.source, attributes: [.font: UIFont.monospacedSystemFont(ofSize: session.baseFontSize, weight: .regular), .foregroundColor: UIColor.label])
        }
        let result = NSMutableAttributedString(string: session.projection.text)
        for span in session.projection.spans where span.range.length > 0 {
            var attributes = attributes(span.attributes, theme: session.theme, baseFontSize: session.baseFontSize)
            if span.isAtomic, let attachment = session.attachment(for: span) { attributes[.attachment] = attachment }
            result.setAttributes(attributes, range: span.range.nsRange)
        }
        for span in session.projection.spans {
            guard case .listMarker = span.kind,
                  let attachment = session.attachment(for: span),
                  let paragraph = (result.attribute(.paragraphStyle, at: span.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { continue }
            paragraph.headIndent = paragraph.firstLineHeadIndent + attachment.size(maxWidth: 640).width
            let range = (result.string as NSString).paragraphRange(for: span.range.nsRange)
            result.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return result
    }

    static func attributes(_ value: ForumComposerTextAttributes, theme: ForumTheme, baseFontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let size = min(max(CGFloat(value.pointSize ?? Double(baseFontSize) * (value.relativeSize ?? 1)), 8), 128) * (value.baseline == 0 ? 1 : 0.72)
        var font = value.fontName.flatMap { UIFont(name: $0, size: size) }
            ?? (value.literal ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size))
        if value.bold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) { font = UIFont(descriptor: descriptor, size: size) }
        if value.italic { font = UIFont(descriptor: font.fontDescriptor.withMatrix(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)), size: size) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.alignment = value.alignment == .center ? .center : value.alignment == .right ? .right : .left
        paragraph.headIndent = CGFloat(value.indentLevel + value.quoteLevel + value.listLevel) * 20
        paragraph.firstLineHeadIndent = paragraph.headIndent + CGFloat(value.firstLineIndent) * size
        if let height = value.lineHeight { paragraph.minimumLineHeight = CGFloat(height); paragraph.maximumLineHeight = max(CGFloat(height), size) }
        if let multiple = value.lineHeightMultiple { paragraph.lineHeightMultiple = CGFloat(min(max(multiple, 0.5), 5)) }
        var style = ForumThreadTextStyle()
        style.foregroundHex = value.foregroundHex
        style.backgroundHex = value.backgroundHex
        let colors = ForumThreadAuthorColorAdapter.colors(for: style, theme: theme)
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.foreground.map(UIColor.init) ?? UIColor.label, .paragraphStyle: paragraph]
        if let background = colors.background { result[.backgroundColor] = UIColor(background) }
        else if value.quoteLevel > 0 { result[.backgroundColor] = UIColor.secondarySystemBackground }
        if value.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if value.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if value.baseline != 0 { result[.baselineOffset] = CGFloat(value.baseline) * size * 0.4 }
        if value.link != nil { result[.underlineStyle] = NSUnderlineStyle.single.rawValue; result[.foregroundColor] = UIColor(theme.accentText) }
        return result
    }

    static func preview(_ source: String, theme: ForumTheme, fontSize: CGFloat, code: Bool = false,
                        images: [String: UIImage] = [:], depth: Int = 0) -> NSAttributedString {
        if code { return NSAttributedString(string: source, attributes: [.font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: UIColor.label]) }
        let document = ForumComposerDocument(source: source)
        let projection = ForumComposerProjection(document: document)
        let result = NSMutableAttributedString(string: "")
        for span in projection.spans {
            let string: String
            if case let .listMarker(marker) = span.kind { string = marker + " " }
            else if span.isAtomic, let node = document.node(id: span.nodeID) {
                let content = document.substring(node.contentRange)
                let imageKey = node.kind == .emoticon ? document.substring(node.range) : content
                if [.img, .attachimg].contains(node.tag) || node.kind == .emoticon, let image = images[imageKey] {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let height: CGFloat = node.kind == .emoticon ? 24 : 72
                    let ratio = image.size.width / max(1, image.size.height)
                    attachment.bounds = CGRect(x: 0, y: -4, width: min(160, height * ratio), height: min(height, 160 / max(0.01, ratio)))
                    result.append(NSAttributedString(attachment: attachment))
                    continue
                }
                let label = node.tag.map(ForumComposerLabels.title) ?? document.substring(node.range)
                if [.collapse, .hide, .free, .float, .ruby, .fly].contains(node.tag), depth < 8 {
                    if case let .collapse(expanded, title) = node.attributes, !expanded { string = "+ " + title }
                    else {
                        if node.tag == .ruby { result.append(NSAttributedString(string: node.parameter + "\n", attributes: [.font: UIFont.systemFont(ofSize: fontSize * 0.6)])) }
                        result.append(preview(content, theme: theme, fontSize: fontSize, images: images, depth: depth + 1))
                        continue
                    }
                } else { string = "[" + label + "]" }
            } else { string = (projection.text as NSString).substring(with: span.range.nsRange) }
            var attributes = span.attributes
            attributes.pointSize = nil
            attributes.relativeSize = min(attributes.relativeSize ?? 1, 1.5)
            result.append(NSAttributedString(string: string, attributes: Self.attributes(attributes, theme: theme, baseFontSize: fontSize)))
        }
        return result
    }
}

@MainActor
final class ForumBBCodeAttachment: NSTextAttachment {
    let node: ForumComposerNode
    let source: String
    let content: String
    let span: ForumComposerSpan
    let baseFontSize: CGFloat
    let plainContent: String
    let table: ForumComposerTable?
    private(set) var bodyPreview = NSAttributedString()
    private(set) var cellPreviews: [String: NSAttributedString] = [:]
    weak var session: ForumBBCodeSession?
    var previewImage: UIImage?
    private var imageTask: Task<Void, Never>?
    private var nestedImageTasks: [Task<Void, Never>] = []
    private var nestedImages: [String: UIImage] = [:]
    private var requestedNestedImages = false
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(node: ForumComposerNode, source: String, span: ForumComposerSpan, session: ForumBBCodeSession) {
        self.node = node; self.source = source; self.span = span; self.session = session; baseFontSize = session.baseFontSize
        content = session.document.substring(node.contentRange)
        plainContent = ForumComposerDocument(source: content).plainText()
        let tableDocument = node.tag == .table ? ForumComposerDocument(source: source) : nil
        table = tableDocument.flatMap { document in document.nodes.first.flatMap { try? ForumComposerTable(document: document, node: $0) } }
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        rebuildPreview()
    }
    required init?(coder: NSCoder) { nil }

    var previewURL: URL? {
        if node.kind == .emoticon { return ForumEmoticonCatalog.categories.flatMap(\.items).first { $0.code == source }?.imageURL }
        if node.tag == .img { return ForumComposerSyntax.safeURL(content) }
        if node.tag == .attachimg || node.tag == .attach { return session?.context.attachments.first { $0.id == content }?.previewURL }
        if node.tag == .postbg { return session?.context.backgrounds.first { $0.name == content }?.imageURL }
        if node.tag == .begin, !content.lowercased().contains(".swf") { return ForumComposerSyntax.safeURL(content) }
        return nil
    }

    func size(maxWidth: CGFloat) -> CGSize {
        let width = max(44, min(maxWidth, 640))
        if case let .listMarker(marker) = span.kind {
            return CGSize(width: max(22, (marker as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: baseFontSize)]).width + 8), height: baseFontSize + 4)
        }
        if node.kind == .emoticon { return CGSize(width: 32, height: 32) }
        if node.tag == .hr { return CGSize(width: width, height: 20) }
        if node.tag == .ruby {
            let base = plainContent as NSString
            let annotation = node.parameter as NSString
            let measured = max(base.size(withAttributes: [.font: UIFont.systemFont(ofSize: baseFontSize)]).width,
                               annotation.size(withAttributes: [.font: UIFont.systemFont(ofSize: baseFontSize * 0.55)]).width)
            return CGSize(width: min(width, max(44, measured + 8)), height: baseFontSize * 1.85)
        }
        if [.img, .attachimg, .begin, .postbg].contains(node.tag) {
            var imageWidth: CGFloat = min(width, 300), imageHeight: CGFloat = 160
            if case let .dimensions(dimensions) = node.attributes {
                imageWidth = Self.dimension(dimensions.width, available: width)
                imageHeight = Self.dimension(dimensions.height, available: 240)
            }
            if let image = previewImage {
                let ratio = image.size.height / max(1, image.size.width)
                imageHeight = min(imageWidth * ratio, 240)
                imageWidth = min(imageWidth, imageHeight / max(0.01, ratio))
            }
            return CGSize(width: max(44, min(imageWidth, width)), height: max(44, min(imageHeight, 240)))
        }
        if case let .collapse(expanded, _) = node.attributes, !expanded { return CGSize(width: width, height: 44) }
        if node.tag == .table {
            let tableWidth = table?.width.map { Self.dimension($0, available: width) } ?? width
            return CGSize(width: max(44, tableWidth), height: CGFloat(min(table?.rowCount ?? 2, 6)) * max(36, baseFontSize * 2.2) + 28)
        }
        if node.tag?.isMedia == true || [.password, .attach, .page, .qq, .groupid].contains(node.tag) || node.isSystem { return CGSize(width: width, height: 64) }
        return CGSize(width: width, height: min(200, max(80, CGFloat(content.split(separator: "\n").count + 1) * baseFontSize * 1.4 + 28)))
    }

    private static func dimension(_ value: ForumComposerLength, available: CGFloat) -> CGFloat {
        switch value { case let .pixels(value): min(CGFloat(value), available); case let .percent(value): available * CGFloat(min(value, 100)) / 100; case .automatic: available }
    }

    override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ForumBBCodeAttachmentProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    func observe(id: UUID, action: @escaping @MainActor () -> Void) { observers[id] = action }
    func stopObserving(id: UUID) { observers[id] = nil }
    func loadImage() {
        loadNestedImages()
        guard imageTask == nil, previewImage == nil, let session else { return }
        if let image = session.localImages[content] { previewImage = image; return }
        guard let url = previewURL, let pipeline = session.imagePipeline else { return }
        imageTask = Task { [weak self] in
            let image = try? await pipeline.image(for: YamiboImageSource(url: url, refererPageURL: session.refererURL))
            guard !Task.isCancelled, let self else { return }
            self.previewImage = image
            for action in self.observers.values { action() }
        }
    }

    func refreshLocalImages() {
        if let image = session?.localImages[content] { previewImage = image }
        rebuildPreview()
        for action in observers.values { action() }
    }

    private func rebuildPreview() {
        let theme = session?.theme ?? .classic
        let images = nestedImages.merging(session?.localImages ?? [:]) { _, local in local }
        bodyPreview = ForumBBCodeTextCodec.preview(content, theme: theme, fontSize: baseFontSize,
                                                  code: node.tag == .code || node.tag?.isMedia == true, images: images)
        if let table {
            for placement in (try? table.placements()) ?? [] where placement.row < 6 {
                cellPreviews[placement.cell.id] = ForumBBCodeTextCodec.preview(placement.cell.source, theme: theme, fontSize: baseFontSize * 0.9, images: images)
            }
        }
    }

    private func loadNestedImages() {
        guard !requestedNestedImages, !node.isSystem, node.tag?.isLiteralBody != true, let session else { return }
        requestedNestedImages = true
        let document = ForumComposerDocument(source: content)
        var sources: [(String, URL)] = []
        func visit(_ nodes: [ForumComposerNode]) {
            for child in nodes where sources.count < 8 {
                let body = document.substring(child.contentRange)
                if child.tag == .img, let url = ForumComposerSyntax.safeURL(body) { sources.append((body, url)) }
                else if child.tag == .attachimg, let url = session.context.attachments.first(where: { $0.id == body })?.previewURL { sources.append((body, url)) }
                else if child.kind == .emoticon, let item = ForumEmoticonCatalog.categories.flatMap(\.items).first(where: { $0.code == body }) { sources.append((body, item.imageURL)) }
                if case let .collapse(expanded, _) = child.attributes, !expanded { continue }
                visit(child.children)
            }
        }
        visit(document.nodes)
        guard let pipeline = session.imagePipeline else { return }
        for (key, url) in sources where session.localImages[key] == nil {
            nestedImageTasks.append(Task { [weak self] in
                guard let image = try? await pipeline.image(for: YamiboImageSource(url: url, refererPageURL: session.refererURL)),
                      !Task.isCancelled, let self else { return }
                self.nestedImages[key] = image
                self.rebuildPreview()
                for action in self.observers.values { action() }
            })
        }
    }

    deinit {
        imageTask?.cancel()
        for task in nestedImageTasks { task.cancel() }
    }
}

@MainActor
final class ForumBBCodeAttachmentProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        // UIKit declares these synchronous callbacks nonisolated. This provider
        // belongs only to the main-actor editor; assert that boundary at runtime.
        nonisolated(unsafe) let attachment = textAttachment as? ForumBBCodeAttachment
        let content = MainActor.assumeIsolated { attachment.map { ForumBBCodePreviewControl(attachment: $0) } }
        view = content
    }
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        nonisolated(unsafe) let attachment = textAttachment as? ForumBBCodeAttachment
        let containerWidth = textContainer?.size.width ?? proposedLineFragment.width
        let fragmentWidth = proposedLineFragment.width > 44 ? proposedLineFragment.width : containerWidth
        let width = max(44, min(fragmentWidth, containerWidth) - 2 * (textContainer?.lineFragmentPadding ?? 5))
        return MainActor.assumeIsolated {
            guard let attachment else { return .zero }
            return CGRect(origin: CGPoint(x: 0, y: -4), size: attachment.size(maxWidth: width))
        }
    }
}

@MainActor
final class ForumBBCodePreviewControl: UIControl {
    let attachment: ForumBBCodeAttachment
    private let observationID = UUID()
    init(attachment: ForumBBCodeAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = attachment.node.isSystem ? .staticText : .button
        accessibilityLabel = attachment.node.tag.map(ForumComposerLabels.title) ?? attachment.source
        accessibilityValue = attachment.node.tag == .password ? L10n.string("forum.composer.password_set") : String(attachment.plainContent.prefix(200))
        addTarget(self, action: #selector(edit), for: .touchUpInside)
        attachment.observe(id: observationID) { [weak self] in self?.setNeedsDisplay() }
        attachment.loadImage()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func edit() { attachment.session?.editNode(attachment.node.id) }
    override func accessibilityActivate() -> Bool { edit(); return true }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let node = attachment.node, size = attachment.baseFontSize
        let theme = attachment.session?.theme ?? .classic
        if case let .listMarker(marker) = attachment.span.kind {
            (marker as NSString).draw(in: bounds, withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.secondaryLabel]); return
        }
        if node.tag == .hr {
            context.setStrokeColor(UIColor.separator.cgColor); context.move(to: CGPoint(x: 0, y: bounds.midY)); context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY)); context.strokePath(); return
        }
        if node.tag == .ruby {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (node.parameter as NSString).draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: size * 0.7), withAttributes: [.font: UIFont.systemFont(ofSize: size * 0.55), .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph])
            (attachment.plainContent as NSString).draw(in: CGRect(x: 0, y: size * 0.7, width: bounds.width, height: size * 1.1), withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]); return
        }
        if let image = attachment.previewImage {
            let scale = min(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
            let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - imageSize.width) / 2, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)); return
        }
        if node.kind == .emoticon {
            UIImage(systemName: "face.smiling")?.withTintColor(.secondaryLabel).draw(in: bounds.insetBy(dx: 3, dy: 3)); return
        }
        UIColor.secondarySystemBackground.setFill(); UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), cornerRadius: 4).fill()
        let title = node.tag.map(ForumComposerLabels.title) ?? "BBCode"
        let detail: String
        if node.tag == .password { detail = L10n.string("forum.composer.password_set") }
        else if case let .collapse(expanded, title) = node.attributes { detail = (expanded ? "− " : "+ ") + title }
        else if node.tag == .hide { detail = title + (node.parameter.isEmpty ? " · " + L10n.string("forum.composer.hide_reply") : " · " + node.parameter) }
        else { detail = title + (node.parameter.isEmpty ? "" : " · " + node.parameter) }
        (detail as NSString).draw(in: CGRect(x: 8, y: 5, width: max(0, bounds.width - 16), height: 24), withAttributes: [.font: UIFont.systemFont(ofSize: min(size, 15), weight: .medium), .foregroundColor: UIColor.secondaryLabel])
        if node.tag == .password || node.tag == .hr { return }
        if case let .collapse(expanded, _) = node.attributes, !expanded { return }
        let area = CGRect(x: 8, y: 29, width: max(0, bounds.width - 16), height: max(0, bounds.height - 34))
        if node.tag == .table, drawTable(in: area, context: context, theme: theme) { return }
        var previewArea = area
        if node.tag == .float {
            previewArea.size.width *= 0.65
            if node.parameter == "right" { previewArea.origin.x = area.maxX - previewArea.width }
        }
        attachment.bodyPreview.draw(with: previewArea, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawTable(in area: CGRect, context: CGContext, theme: ForumTheme) -> Bool {
        guard let table = attachment.table, let placements = try? table.placements() else { return false }
        let cellWidth = area.width / CGFloat(max(1, table.columnCount)), rowHeight = area.height / CGFloat(max(1, min(6, table.rowCount)))
        context.saveGState(); context.clip(to: area); defer { context.restoreGState() }
        for placement in placements where placement.row < 6 {
            let rect = CGRect(x: area.minX + CGFloat(placement.column) * cellWidth, y: area.minY + CGFloat(placement.row) * rowHeight, width: CGFloat(placement.cell.columnSpan) * cellWidth, height: CGFloat(placement.cell.rowSpan) * rowHeight)
            let color = table.rows.indices.contains(placement.row) ? table.rows[placement.row].background ?? table.background : table.background
            if let color {
                var attributes = ForumComposerTextAttributes(); attributes.backgroundHex = color
                (ForumBBCodeTextCodec.attributes(attributes, theme: theme, baseFontSize: 14)[.backgroundColor] as? UIColor)?.setFill()
                context.fill(rect)
            }
            context.setStrokeColor(UIColor.separator.cgColor); context.stroke(rect, width: 0.5)
            attachment.cellPreviews[placement.cell.id]?.draw(with: rect.insetBy(dx: 4, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        return true
    }
}
