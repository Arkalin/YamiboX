import YamiboXCore

#if canImport(UIKit)
import SwiftUI
import UIKit

struct NativeNovelTextViewportReferenceView: UIViewRepresentable {
    let displayReference: NovelTextViewportDisplayReference
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?

    init(
        displayReference: NovelTextViewportDisplayReference,
        selectionController: NovelTextSelectionController? = nil,
        likeHighlightController: NovelLikeHighlightController? = nil
    ) {
        self.displayReference = displayReference
        self.selectionController = selectionController
        self.likeHighlightController = likeHighlightController
    }

    func makeUIView(context: Context) -> NovelTextViewportReferenceUIView {
        NovelTextViewportReferenceUIView()
    }

    func updateUIView(_ uiView: NovelTextViewportReferenceUIView, context: Context) {
        uiView.displayReference = displayReference
        uiView.selectionController = selectionController
        uiView.likeHighlightController = likeHighlightController
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

    private var lastDrawBounds: CGRect = .zero
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    private lazy var likeHighlightTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleLikeHighlightTap(_:))
    )
    private var startHandleView: NovelSelectionHandleUIView?
    private var endHandleView: NovelSelectionHandleUIView?
    private static let selectionHandleKnobDiameter: CGFloat = 14

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
        guard let displayReference = self.displayReference else {
            return
        }
        guard !displayReference.isStale else {
            return
        }
        displayReference.drawBlockBackgrounds(in: context, bounds: self.bounds)
        drawLikeHighlights(
            displayReference: displayReference,
            in: context
        )
        drawSelectionHighlight(
            displayReference: displayReference,
            in: context
        )
        displayReference.drawText(in: context, bounds: self.bounds)
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
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard selectionController?.hasSelection == true else { return nil }
        let extraActions = [makeLikeAction(), makeShareAction(), makeLookUpAction()].compactMap { $0 }
        if !suggestedActions.isEmpty {
            return UIMenu(children: suggestedActions + extraActions)
        }
        let copyAction = UIAction(
            title: L10n.string("reader.copy")
        ) { [weak self] _ in
            self?.selectionController?.copySelection()
        }
        return UIMenu(children: [copyAction] + extraActions)
    }

    // A3: the edit menu simply omits "add to likes" when the selection can't
    // resolve to a semantic position (no chapter title on that content).
    private func makeLikeAction() -> UIAction? {
        guard selectionController?.canLike == true else { return nil }
        // The menu is about to offer "add to likes" — give the reader a
        // chance to prepare its haptic generator before the user can tap it.
        selectionController?.noteLikeActionOffered()
        return UIAction(title: L10n.string("likes.add_to_likes")) { [weak self] _ in
            self?.selectionController?.likeSelection()
        }
    }

    private func makeShareAction() -> UIAction? {
        guard selectionController?.selectedText() != nil else { return nil }
        return UIAction(title: L10n.string("common.share")) { [weak self] _ in
            self?.presentShareSheet()
        }
    }

    private func presentShareSheet() {
        guard let text = selectionController?.selectedText(),
              let presenter = nearestViewController else {
            return
        }
        let activityViewController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = selectionController?.menuTargetRect(in: self) ?? bounds
        }
        presenter.present(activityViewController, animated: true)
    }

    private func makeLookUpAction() -> UIAction? {
        guard let text = selectionController?.selectedText(),
              UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text) else {
            return nil
        }
        return UIAction(title: L10n.string("reader.look_up")) { [weak self] _ in
            self?.presentLookUp(for: text)
        }
    }

    private func presentLookUp(for term: String) {
        guard let presenter = nearestViewController else { return }
        presenter.present(UIReferenceLibraryViewController(term: term), animated: true)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionController?.menuTargetRect(in: self) ?? bounds
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
        likeHighlightTapRecognizer.delegate = self
        addGestureRecognizer(likeHighlightTapRecognizer)
    }

    // Only recognized when the tap actually lands on a highlight rect; every
    // other single tap fails immediately and falls through untouched to the
    // viewport-level tap gesture (chrome toggle, page turn, etc.).
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

    // Takes `controller` explicitly rather than reading `self.likeHighlightController`
    // from inside the action closures, so the "remove" action doesn't need to
    // capture `self` across the async `Task` boundary.
    private func presentLikeHighlightMenu(
        for item: LikeItem,
        controller: NovelLikeHighlightController,
        at location: CGPoint
    ) {
        guard let presenter = nearestViewController else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.string("reader.copy"), style: .default) { _ in
            UIPasteboard.general.string = item.excerptText
        })
        alert.addAction(UIAlertAction(title: L10n.string("likes.remove_like"), style: .destructive) { _ in
            Task { await controller.remove(item) }
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(origin: location, size: .zero).insetBy(dx: -8, dy: -8)
        }
        presenter.present(alert, animated: true)
    }

    private var nearestViewController: UIViewController? {
        sequence(first: next) { $0?.next }.compactMap { $0 as? UIViewController }.first
    }

    private var nearestScrollView: UIScrollView? {
        sequence(first: superview) { $0?.superview }.compactMap { $0 as? UIScrollView }.first
    }

    private func drawLikeHighlights(
        displayReference: NovelTextViewportDisplayReference,
        in context: CGContext
    ) {
        guard let likeHighlightController else { return }
        let highlights = likeHighlightController.highlights(for: displayReference)
        guard !highlights.isEmpty else { return }
        context.saveGState()
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.28).cgColor)
        for entry in highlights {
            for rect in entry.rects {
                context.fill(rect.insetBy(dx: -1, dy: -1))
            }
        }
        context.restoreGState()
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
            showCopyMenu()
        case .cancelled, .failed:
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
            showCopyMenu()
        case .cancelled, .failed:
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

    /// Finds this specific character's on-screen rect the same way
    /// `selectionRects(for:)` finds every character's rect for the highlight
    /// fill above — a synthetic one-character range through the same
    /// windowed, per-surface query. Returns nil when the true global
    /// endpoint isn't hosted by this surface (e.g. an adjacent, still-
    /// registered page in vertical mode), so a handle never appears at a
    /// merely-local edge of a selection that spans multiple surfaces.
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
final class NovelSelectionHandleUIView: UIView {
    let kind: NovelTextSelectionController.HandleKind
    private let touchTargetPadding: CGFloat = -15

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
        bounds.insetBy(dx: touchTargetPadding, dy: touchTargetPadding).contains(point)
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
