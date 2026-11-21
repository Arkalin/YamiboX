import YamiboXCore

#if canImport(UIKit)
import SwiftUI
import UIKit

struct NativeNovelTextViewportReferenceView: UIViewRepresentable {
    let displayReference: NovelTextViewportDisplayReference
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let searchHighlightController: NovelReaderSearchHighlightController?

    init(
        displayReference: NovelTextViewportDisplayReference,
        selectionController: NovelTextSelectionController? = nil,
        likeHighlightController: NovelLikeHighlightController? = nil,
        searchHighlightController: NovelReaderSearchHighlightController? = nil
    ) {
        self.displayReference = displayReference
        self.selectionController = selectionController
        self.likeHighlightController = likeHighlightController
        self.searchHighlightController = searchHighlightController
    }

    func makeUIView(context: Context) -> NovelTextViewportReferenceUIView {
        NovelTextViewportReferenceUIView()
    }

    func updateUIView(_ uiView: NovelTextViewportReferenceUIView, context: Context) {
        uiView.displayReference = displayReference
        uiView.selectionController = selectionController
        uiView.likeHighlightController = likeHighlightController
        uiView.searchHighlightController = searchHighlightController
    }
}

struct NativeNovelTextSettingsPreviewView: UIViewRepresentable {
    let surface: NovelTextSettingsPreviewSurface

    func makeUIView(context: Context) -> NovelTextSettingsPreviewUIView {
        NovelTextSettingsPreviewUIView()
    }

    func updateUIView(_ uiView: NovelTextSettingsPreviewUIView, context: Context) {
        uiView.surface = surface
    }
}

@MainActor
final class NovelTextViewportReferenceUIView: UIView, @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var displayReference: NovelTextViewportDisplayReference? {
        didSet {
            guard oldValue !== displayReference else { return }
            selectionController?.refreshSelectionDisplay()
            setNeedsDisplay()
        }
    }

    weak var selectionController: NovelTextSelectionController? {
        didSet {
            guard oldValue !== selectionController else { return }
            oldValue?.unregister(self)
            selectionController?.register(self)
            setNeedsDisplay()
        }
    }

    weak var likeHighlightController: NovelLikeHighlightController? {
        didSet {
            guard oldValue !== likeHighlightController else { return }
            oldValue?.unregister(self)
            likeHighlightController?.register(self)
            setNeedsDisplay()
        }
    }

    weak var searchHighlightController: NovelReaderSearchHighlightController? {
        didSet {
            guard oldValue !== searchHighlightController else { return }
            oldValue?.unregister(self)
            searchHighlightController?.register(self)
            setNeedsDisplay()
        }
    }

    private var lastDrawBounds: CGRect = .zero
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    private lazy var annotationMenuInteraction = UIEditMenuInteraction(delegate: self)

    private struct PendingAnnotationMenu {
        let item: LikeItem
        let anchorRect: CGRect
        weak var controller: NovelLikeHighlightController?
    }

    private var pendingAnnotationMenu: PendingAnnotationMenu?

    private lazy var styleRowInteraction = UIEditMenuInteraction(delegate: self)

    private var pendingStyleRow: ((LikeStyle) -> Void)?
    private var styleRowAnchorRect: CGRect = .zero
    private lazy var likeHighlightTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleLikeHighlightTap(_:))
    )
    private var startHandleView: NovelSelectionHandleUIView?
    private var endHandleView: NovelSelectionHandleUIView?
    private var noteBadgeViewsByItemID: [String: NovelLikeNoteBadgeUIView] = [:]
    private static let selectionHandleKnobDiameter: CGFloat = 14

    func remoteTextHit(at point: CGPoint, in window: UIWindow) -> Bool {
        guard let reference = displayReference, !reference.isStale,
              let anchor = reference.selectionAnchor(at: convert(point, from: window)),
              let glyph = NovelTextSelectionRange(generation: anchor.generation, lowerBound: anchor.documentOffset,
                                                 upperBound: anchor.documentOffset + 1) else { return false }
        let local = convert(point, from: window)
        return reference.selectionRects(for: glyph).contains { $0.contains(local) }
    }

    func remoteHandle(at point: CGPoint, in window: UIWindow) -> NovelTextSelectionController.HandleKind? {
        if startHandleView?.readerContains(windowPoint: point, in: window, slop: NovelSelectionHandleUIView.touchTargetPadding) == true { return .start }
        if endHandleView?.readerContains(windowPoint: point, in: window, slop: NovelSelectionHandleUIView.touchTargetPadding) == true { return .end }
        return nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSurface()
    }

    override func draw(_ rect: CGRect) {
        guard self.bounds.width > 0, self.bounds.height > 0 else {
            return
        }
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.clear(self.bounds)
        hideSelectionHandles()
        hideNoteBadges()
        guard let displayReference = self.displayReference else {
            return
        }
        guard !displayReference.isStale else {
            return
        }
        displayReference.drawBlockBackgrounds(in: context, bounds: self.bounds)
        let likeHighlights = likeHighlightController?.highlights(for: displayReference) ?? []
        drawLikeHighlights(
            highlights: likeHighlights,
            in: context
        )
        drawSearchHighlight(
            displayReference: displayReference,
            in: context
        )
        drawSelectionHighlight(
            displayReference: displayReference,
            in: context
        )
        displayReference.drawText(in: context, bounds: self.bounds)
        drawLikeNoteBadges(highlights: likeHighlights, in: context)
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copy(_:)) && selectionController?.hasSelection == true
    }

    override func copy(_ sender: Any?) {
        selectionController?.copySelection()
    }

    func dismissCopyMenu() {
        editMenuInteraction.dismissMenu()
        // The annotation menu would otherwise outlive the annotation it acts
        // on across a selection change, a page turn, or the reader itself.
        annotationMenuInteraction.dismissMenu()
        pendingAnnotationMenu = nil
        styleRowInteraction.dismissMenu()
        pendingStyleRow = nil
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if interaction === styleRowInteraction {
            return makeStyleRowMenu()
        }
        guard let selectionController else { return nil }
        let annotation = interaction === annotationMenuInteraction ? pendingAnnotationMenu : nil
        if interaction === annotationMenuInteraction {
            guard annotation?.controller != nil else { return nil }
        } else if !selectionController.hasSelection {
            return nil
        }
        let anchor = annotation?.anchorRect ?? selectionController.menuTargetRect(in: self)
        let menu = selectionController.textMenu(
            item: annotation?.item, highlights: annotation?.controller,
            share: { [weak self] text in
                guard let self, let presenter = self.nearestViewController else { return }
                let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                controller.popoverPresentationController?.sourceView = self
                controller.popoverPresentationController?.sourceRect = anchor
                presenter.present(controller, animated: true)
            },
            lookUp: { [weak self] term in
                self?.nearestViewController?.present(UIReferenceLibraryViewController(term: term), animated: true)
            }
        )
        return UIMenu(children: menu.actions.map { action in
            switch action.command {
            case let .perform(perform):
                UIAction(title: action.title, attributes: action.destructive ? .destructive : []) { _ in perform() }
            case let .styles(choose):
                UIAction(title: action.title) { [weak self] _ in self?.presentStyleRow(choose, anchorRect: anchor) }
            case let .disabled(reason):
                UIAction(title: action.title, subtitle: reason, attributes: .disabled) { _ in }
            }
        })
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        if interaction === styleRowInteraction {
            return styleRowAnchorRect
        }
        if interaction === annotationMenuInteraction {
            return pendingAnnotationMenu?.anchorRect ?? bounds
        }
        return selectionController?.menuTargetRect(in: self) ?? bounds
    }

    private func presentStyleRow(_ context: @escaping (LikeStyle) -> Void, anchorRect: CGRect) {
        pendingStyleRow = context
        styleRowAnchorRect = anchorRect
        becomeFirstResponder()
        // The menu whose action triggered this is still tearing down; presenting
        // on the same turn of the runloop is swallowed by that dismissal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.styleRowInteraction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: CGPoint(x: anchorRect.midX, y: anchorRect.minY)
                )
            )
        }
    }

    private func makeStyleRowMenu() -> UIMenu? {
        pendingStyleRow.map { NovelLikeStyleMenu.makeRoot(onSelect: $0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard self.bounds != self.lastDrawBounds else { return }
        self.lastDrawBounds = self.bounds
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard self.window != nil else { return }
        setNeedsDisplay()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        annotationMenuInteraction.dismissMenu()
        pendingAnnotationMenu = nil
        styleRowInteraction.dismissMenu()
        pendingStyleRow = nil
    }

    private func configureSurface() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        clearsContextBeforeDrawing = true
        contentMode = .redraw
        let longPressRecognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        longPressRecognizer.minimumPressDuration = 0.35
        addGestureRecognizer(longPressRecognizer)
        addInteraction(editMenuInteraction)
        addInteraction(annotationMenuInteraction)
        addInteraction(styleRowInteraction)
        likeHighlightTapRecognizer.delegate = self
        addGestureRecognizer(likeHighlightTapRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === likeHighlightTapRecognizer else { return true }
        return likeHighlightController?.item(at: touch.location(in: self), in: self) != nil
    }

    @objc private func handleLikeHighlightTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        guard let likeHighlightController,
              let item = likeHighlightController.item(at: location, in: self) else {
            return
        }
        presentLikeHighlightMenu(for: item, controller: likeHighlightController, at: location)
    }

    private func presentLikeHighlightMenu(
        for item: LikeItem,
        controller: NovelLikeHighlightController,
        at location: CGPoint
    ) {
        let anchorRect = controller.unionRect(for: item, in: self)
            ?? CGRect(origin: location, size: .zero).insetBy(dx: -8, dy: -8)
        pendingAnnotationMenu = PendingAnnotationMenu(
            item: item,
            anchorRect: anchorRect,
            controller: controller
        )
        becomeFirstResponder()
        annotationMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: anchorRect.midX, y: anchorRect.minY)
            )
        )
    }


    private var nearestViewController: UIViewController? {
        sequence(first: next) { $0?.next }.compactMap { $0 as? UIViewController }.first
    }

    private var nearestScrollView: UIScrollView? {
        sequence(first: superview) { $0?.superview }.compactMap { $0 as? UIScrollView }.first
    }

    private func drawLikeHighlights(
        highlights: [NovelLikeHighlightController.ResolvedHighlight],
        in context: CGContext
    ) {
        guard !highlights.isEmpty else { return }
        context.saveGState()
        for entry in highlights {
            let style = entry.item.style
            // Resolved against this view's traits so the dynamic system
            // colours pick up light/dark from the reader theme in effect.
            context.setFillColor(
                LikeStyleAppearance.paintColor(for: style).resolvedColor(with: traitCollection).cgColor
            )
            for rect in entry.rects {
                context.fill(LikeStyleAppearance.paintedRect(for: style, in: rect))
            }
        }
        context.restoreGState()
    }

    private func drawSearchHighlight(
        displayReference: NovelTextViewportDisplayReference,
        in context: CGContext
    ) {
        guard let highlight = searchHighlightController?.resolvedHighlight(for: displayReference) else {
            return
        }
        context.saveGState()
        context.setFillColor(
            UIColor.systemYellow.withAlphaComponent(0.32 * highlight.opacity).cgColor
        )
        for rect in highlight.rects {
            context.fill(rect.insetBy(dx: -1, dy: 0))
        }
        context.restoreGState()
    }

    private func drawLikeNoteBadges(
        highlights: [NovelLikeHighlightController.ResolvedHighlight],
        in context: CGContext
    ) {
        let annotated = highlights
            .filter { $0.item.hasNote && $0.startRect != nil }
        pruneNoteBadgeViews(keeping: Set(annotated.map(\.item.id)))
        guard !annotated.isEmpty else { return }
        context.saveGState()
        for entry in annotated {
            guard let startRect = entry.startRect else { continue }
            let badgeRect = LikeStyleAppearance.noteBadgeRect(anchoredTo: startRect)

            context.setBlendMode(.clear)
            context.addPath(UIBezierPath(
                roundedRect: badgeRect,
                cornerRadius: LikeStyleAppearance.noteBadgeCornerRadius(forSide: badgeRect.width)
            ).cgPath)
            context.fillPath()
            context.setBlendMode(.normal)

            let badgeView = noteBadgeView(for: entry.item.id)
            badgeView.frame = badgeRect
            badgeView.ringColor = LikeStyleAppearance.baseColor(for: entry.item.style)
            badgeView.isHidden = false
        }
        context.restoreGState()
    }

    private func hideNoteBadges() {
        for view in noteBadgeViewsByItemID.values {
            view.isHidden = true
        }
    }

    private func pruneNoteBadgeViews(keeping itemIDs: Set<String>) {
        for (id, view) in noteBadgeViewsByItemID where !itemIDs.contains(id) {
            view.removeFromSuperview()
            noteBadgeViewsByItemID[id] = nil
        }
    }

    private func noteBadgeView(for itemID: String) -> NovelLikeNoteBadgeUIView {
        if let existing = noteBadgeViewsByItemID[itemID] { return existing }
        let view = NovelLikeNoteBadgeUIView()
        noteBadgeViewsByItemID[itemID] = view
        addSubview(view)
        return view
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let selectionController else { return }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard selectionController.beginSelection(in: self, at: point) else { return }
            becomeFirstResponder()
            dismissCopyMenu()
        case .changed:
            selectionController.updateSelection(in: self, at: point)
        case .ended:
            selectionController.updateSelection(in: self, at: point)
            selectionController.finishSelectionDrag()
            showCopyMenu()
        case .cancelled, .failed:
            selectionController.finishSelectionDrag()
            dismissCopyMenu()
        default:
            break
        }
    }

    @objc private func handleSelectionHandlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let handle = recognizer.view as? NovelSelectionHandleUIView,
              let selectionController,
              let displayReference else {
            return
        }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            guard selectionController.beginHandleDrag(handle.kind, generation: displayReference.generation) else { return }
            dismissCopyMenu()
        case .changed:
            selectionController.updateSelection(in: self, at: point)
        case .ended:
            selectionController.updateSelection(in: self, at: point)
            selectionController.finishSelectionDrag()
            showCopyMenu()
        case .cancelled, .failed:
            selectionController.finishSelectionDrag()
            selectionController.refreshSelectionDisplay()
        default:
            break
        }
    }

    private func showCopyMenu() {
        guard selectionController?.hasSelection == true else { return }
        let targetRect = selectionController?.menuTargetRect(in: self) ?? bounds
        editMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: targetRect.midX, y: targetRect.minY)
            )
        )
    }

    private func hideSelectionHandles() {
        startHandleView?.isHidden = true
        endHandleView?.isHidden = true
    }

    private func handleView(for kind: NovelTextSelectionController.HandleKind) -> NovelSelectionHandleUIView {
        switch kind {
        case .start:
            if let startHandleView { return startHandleView }
            let handle = makeSelectionHandleView(kind: .start)
            startHandleView = handle
            return handle
        case .end:
            if let endHandleView { return endHandleView }
            let handle = makeSelectionHandleView(kind: .end)
            endHandleView = handle
            return handle
        }
    }

    private func makeSelectionHandleView(kind: NovelTextSelectionController.HandleKind) -> NovelSelectionHandleUIView {
        let handle = NovelSelectionHandleUIView(kind: kind)
        handle.isHidden = true
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        handle.addGestureRecognizer(panRecognizer)
        addSubview(handle)
        nearestScrollView?.panGestureRecognizer.require(toFail: panRecognizer)
        return handle
    }

    private func positionSelectionHandle(kind: NovelTextSelectionController.HandleKind, endpointRect: CGRect?) {
        guard let endpointRect else { return }
        let handle = handleView(for: kind)
        let diameter = Self.selectionHandleKnobDiameter
        let centerX = kind == .start ? endpointRect.minX : endpointRect.maxX
        handle.frame = CGRect(
            x: centerX - diameter / 2,
            y: endpointRect.maxY - diameter / 2,
            width: diameter,
            height: diameter
        )
        handle.isHidden = false
    }

    private func selectionEndpointRect(
        displayReference: NovelTextViewportDisplayReference,
        range: NovelTextSelectionRange,
        isStart: Bool
    ) -> CGRect? {
        let lowerBound = isStart ? range.lowerBound : max(range.lowerBound, range.upperBound - 1)
        guard let characterRange = NovelTextSelectionRange(
            generation: range.generation,
            lowerBound: lowerBound,
            upperBound: lowerBound + 1
        ) else {
            return nil
        }
        return displayReference.selectionRects(for: characterRange).first
    }

    private func updateSelectionHandles(
        displayReference: NovelTextViewportDisplayReference,
        range: NovelTextSelectionRange
    ) {
        positionSelectionHandle(
            kind: .start,
            endpointRect: selectionEndpointRect(displayReference: displayReference, range: range, isStart: true)
        )
        positionSelectionHandle(
            kind: .end,
            endpointRect: selectionEndpointRect(displayReference: displayReference, range: range, isStart: false)
        )
    }

    private func drawSelectionHighlight(
        displayReference: NovelTextViewportDisplayReference,
        in context: CGContext
    ) {
        guard let selectionController,
              let range = selectionController.selectionRange(for: displayReference) else {
            return
        }
        let rects = displayReference.selectionRects(for: range)
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.setFillColor(tintColor.withAlphaComponent(0.22).cgColor)
        for rect in rects {
            context.fill(rect.insetBy(dx: -1, dy: -1))
        }
        context.setFillColor(tintColor.withAlphaComponent(0.85).cgColor)
        if let first = rects.first {
            context.fill(
                CGRect(
                    x: first.minX - 2,
                    y: first.minY,
                    width: 3,
                    height: max(first.height, 12)
                )
            )
        }
        if let last = rects.last {
            context.fill(
                CGRect(
                    x: last.maxX - 1,
                    y: last.minY,
                    width: 3,
                    height: max(last.height, 12)
                )
            )
        }
        context.restoreGState()
        updateSelectionHandles(displayReference: displayReference, range: range)
    }
}

@MainActor
final class NovelLikeNoteBadgeUIView: UIView {
    var ringColor: UIColor = .label {
        didSet {
            guard ringColor != oldValue else { return }
            setNeedsDisplay()
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ringWidth = LikeStyleAppearance.noteBadgeRingWidth(forSide: bounds.width)
        let ringRect = bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
        context.setStrokeColor(ringColor.resolvedColor(with: traitCollection).cgColor)
        context.setLineWidth(ringWidth)
        context.addPath(UIBezierPath(
            roundedRect: ringRect,
            cornerRadius: LikeStyleAppearance.noteBadgeCornerRadius(forSide: ringRect.width)
        ).cgPath)
        context.strokePath()
    }
}

@MainActor
final class NovelSelectionHandleUIView: UIView {
    let kind: NovelTextSelectionController.HandleKind
    static let touchTargetPadding: CGFloat = 15

    init(kind: NovelTextSelectionController.HandleKind) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchTargetPadding, dy: -Self.touchTargetPadding).contains(point)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(tintColor.cgColor)
        context.fillEllipse(in: bounds)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5))
    }
}

@MainActor
final class NovelTextSettingsPreviewUIView: UIView {
    var surface: NovelTextSettingsPreviewSurface? {
        didSet {
            guard oldValue !== surface else { return }
            setNeedsDisplay()
        }
    }

    private var lastDrawBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSurface()
    }

    override func draw(_ rect: CGRect) {
        guard self.bounds.width > 0, self.bounds.height > 0 else {
            return
        }
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.clear(self.bounds)
        surface?.draw(in: context, bounds: self.bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard self.bounds != self.lastDrawBounds else { return }
        self.lastDrawBounds = self.bounds
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard self.window != nil else { return }
        setNeedsDisplay()
    }

    private func configureSurface() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clearsContextBeforeDrawing = true
        contentMode = .redraw
    }
}
#endif
