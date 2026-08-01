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
    /// Kept separate from `editMenuInteraction` rather than told apart by
    /// configuration identifier: this one presents with no text selection,
    /// which is the exact condition under which the selection menu declines to
    /// build itself.
    private lazy var annotationMenuInteraction = UIEditMenuInteraction(delegate: self)

    /// The annotation an annotation menu is being presented for, held across
    /// `presentEditMenu` because the menu is not built until the delegate is
    /// called back.
    private struct PendingAnnotationMenu {
        let item: LikeItem
        let anchorRect: CGRect
        /// Weak for the same reason this view's own reference is: the
        /// controller registers the view, so a strong hop back would close the
        /// loop.
        weak var controller: NovelLikeHighlightController?
    }

    private var pendingAnnotationMenu: PendingAnnotationMenu?

    /// The style row is presented as its own edit menu rather than nested under
    /// 「喜欢」, because only a root menu renders as the horizontal bar.
    private lazy var styleRowInteraction = UIEditMenuInteraction(delegate: self)

    /// What picking a swatch should do.
    private enum StyleRowContext {
        /// Nothing exists yet: the pick captures the live selection in that
        /// style, so a colour is chosen once rather than set and then corrected.
        case capture
        case restyle(LikeItem, NovelLikeHighlightController)
    }

    private var pendingStyleRow: StyleRowContext?
    private var styleRowAnchorRect: CGRect = .zero
    private lazy var likeHighlightTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleLikeHighlightTap(_:))
    )
    private var startHandleView: NovelSelectionHandleUIView?
    private var endHandleView: NovelSelectionHandleUIView?
    /// Ring views for note badges, keyed by item id. Subviews rather than
    /// strokes in `draw(_:)` because a view's drawn content physically cannot
    /// exceed its backing store — a badge straddling the first character of a
    /// line (or the first line of a surface) reaches outside the bounds, and
    /// only subview rendering survives out there (`clipsToBounds` stays false).
    private var noteBadgeViewsByItemID: [String: NovelLikeNoteBadgeUIView] = [:]
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
        hideNoteBadges()
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
        // After the glyphs on purpose: `drawText` paints last, so a badge drawn
        // in the highlight pass would end up underneath the text.
        drawLikeNoteBadges(displayReference: displayReference, in: context)
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
        if interaction === annotationMenuInteraction {
            return makeAnnotationMenu()
        }
        guard selectionController?.hasSelection == true else { return nil }
        // Ordered explicitly rather than appended after `suggestedActions`: the
        // bar shows six items before it paginates, so anything the system
        // prepends would push this menu's own actions behind the `›`.
        let copyAction = UIAction(
            title: L10n.string("reader.copy")
        ) { [weak self] _ in
            self?.selectionController?.copySelection()
        }
        return UIMenu(children: [
            makeLikeElement(),
            // A fresh selection has nothing to edit yet, so this is always the
            // "add" wording — unlike the menu for an existing annotation.
            makeAddNoteAction(),
            copyAction,
            makeShareAction(),
            makeLookUpAction(),
        ].compactMap { $0 })
    }

    // A3: the edit menu omits "add to likes" entirely when the selection
    // can't resolve to a semantic position (no chapter title on that content).
    // A selection that merely crosses a post boundary is different: it is
    // resolvable at both ends and is almost always a slip, so the action stays
    // visible and says why it is off rather than vanishing.
    private func makeLikeElement() -> UIMenuElement? {
        switch selectionController?.likeAvailability {
        case .none, .unavailable:
            return nil
        case .crossesChapters:
            // Stays an action rather than the style submenu: a `UIMenu` cannot
            // carry `.disabled`, and the whole point of this branch is to be
            // visible and say why it is off.
            let action = UIAction(
                title: L10n.string("likes.add_to_likes"),
                subtitle: L10n.string("likes.cannot_span_posts")
            ) { _ in }
            action.attributes = .disabled
            return action
        case .available:
            // The menu is about to offer 「喜欢」 — give the reader a chance to
            // prepare its haptic generator before the user can tap it.
            selectionController?.noteLikeActionOffered()
            return UIAction(title: L10n.string("likes.add_to_likes")) { [weak self] _ in
                guard let self else { return }
                self.presentStyleRow(
                    .capture,
                    anchorRect: self.selectionController?.menuTargetRect(in: self) ?? self.bounds
                )
            }
        }
    }

    /// Captures and opens the editor in one step, so a note can be the reason
    /// for annotating rather than something bolted on afterwards.
    private func makeAddNoteAction() -> UIAction? {
        guard selectionController?.likeAvailability == .available else { return nil }
        return UIAction(title: L10n.string("likes.add_note")) { [weak self] _ in
            self?.selectionController?.likeSelection(thenAddNote: true)
        }
    }

    private func makeShareAction() -> UIAction? {
        guard selectionController?.selectedText() != nil else { return nil }
        return UIAction(title: L10n.string("common.share")) { [weak self] _ in
            self?.presentShareSheet()
        }
    }

    private func presentShareSheet(for text: String? = nil) {
        guard let text = text ?? selectionController?.selectedText(),
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
        if interaction === styleRowInteraction {
            return styleRowAnchorRect
        }
        if interaction === annotationMenuInteraction {
            // The annotation's own rect, so the system places the menu clear of
            // the text being acted on rather than over it.
            return pendingAnnotationMenu?.anchorRect ?? bounds
        }
        return selectionController?.menuTargetRect(in: self) ?? bounds
    }

    /// Reopens at the same anchor as the menu that asked for it, so the row
    /// lands where the menu the user just tapped was.
    private func presentStyleRow(_ context: StyleRowContext, anchorRect: CGRect) {
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
        guard let context = pendingStyleRow else { return nil }
        return NovelLikeStyleMenu.makeRoot { [weak self] style in
            switch context {
            case .capture:
                self?.selectionController?.likeSelection(style: style)
            case let .restyle(item, controller):
                // Paint immediately, persist behind it — same contract as the
                // optimistic paint on capture.
                controller.applyStyleOptimistically(itemID: item.id, style: style)
                ReaderHighlightStyleDefault.set(style)
                Task { await controller.updateStyle(item, to: style) }
            }
        }
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

    /// The menu is presented above this view rather than inside it, so nothing
    /// takes it down when the reader is dismissed, a page is recycled, or this
    /// surface is otherwise detached — it would be left floating over whatever
    /// screen came next.
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

    /// Entry point for an existing annotation, from a tap on it or from the
    /// annotation panel.
    ///
    /// Takes `controller` explicitly rather than reading
    /// `self.likeHighlightController` from inside the action closures, so the
    /// actions don't need to capture `self` across an async `Task` boundary.
    func presentLikeAnnotationMenu(for item: LikeItem) -> Bool {
        guard let likeHighlightController,
              let anchorRect = likeHighlightController.unionRect(for: item, in: self) else {
            return false
        }
        presentLikeHighlightMenu(for: item, controller: likeHighlightController, at: anchorRect.origin)
        return true
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
        // An edit menu only presents from the first responder, and the tap that
        // opens this one does not go through the selection path that would
        // otherwise have claimed it.
        becomeFirstResponder()
        annotationMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: anchorRect.midX, y: anchorRect.minY)
            )
        )
    }

    /// The menu for an annotation that already exists: the same shape as the
    /// selection menu, with the note action switched to editing and a remove
    /// action added. Five items, which is inside the bar's six-item ceiling.
    private func makeAnnotationMenu() -> UIMenu? {
        guard let pending = pendingAnnotationMenu, let controller = pending.controller else {
            return nil
        }
        let item = pending.item
        let anchorRect = pending.anchorRect
        var children: [UIMenuElement] = []

        children.append(UIAction(title: L10n.string("likes.add_to_likes")) { [weak self] _ in
            self?.presentStyleRow(.restyle(item, controller), anchorRect: anchorRect)
        })

        // Says what tapping it will actually do: this annotation either has a
        // note to open or doesn't have one yet.
        let noteTitle = item.hasNote
            ? L10n.string("likes.edit_note")
            : L10n.string("likes.add_note")
        children.append(UIAction(title: noteTitle) { [weak self] _ in
            self?.selectionController?.requestNoteEditor(for: item)
        })

        let excerpt = item.excerptText.flatMap { $0.isEmpty ? nil : $0 }
        if let excerpt {
            children.append(UIAction(title: L10n.string("reader.copy")) { _ in
                UIPasteboard.general.string = excerpt
            })
        }

        let remove = UIAction(title: L10n.string("likes.remove_like")) { _ in
            Task { await controller.remove(item) }
        }
        remove.attributes = .destructive
        children.append(remove)

        if let excerpt {
            children.append(UIAction(title: L10n.string("common.share")) { [weak self] _ in
                self?.presentShareSheet(for: excerpt)
            })
        }
        return UIMenu(children: children)
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

    /// A note is otherwise invisible — an annotated highlight looks identical
    /// to a bare one. The badge is an indicator only: the whole highlight stays
    /// a single hit target, so there is nothing to mis-tap.
    ///
    /// Split across two layers on purpose. The paper-coloured centre is punched
    /// out of THIS view's content with a `.clear` blend — the surface is
    /// transparent over the themed page background, so erasing IS the paper
    /// colour on all six themes, with no colour plumbed in. The ring is a
    /// subview, because the punch (like any `draw(_:)` output) stops at the
    /// view bounds and a badge on a line's first character straddles them —
    /// outside the bounds there is nothing drawn to erase anyway, so the two
    /// halves meet seamlessly.
    private func drawLikeNoteBadges(
        displayReference: NovelTextViewportDisplayReference,
        in context: CGContext
    ) {
        guard let likeHighlightController else { return }
        // `startRect` is nil when the annotation began on another surface,
        // which is exactly when this page must not claim to show its beginning.
        let annotated = likeHighlightController.highlights(for: displayReference)
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

    /// Views for items that lost their note (or left this surface) are removed
    /// rather than merely hidden, so the pool tracks the annotation set instead
    /// of growing with everything ever shown.
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

/// The ring half of a note badge (see `drawLikeNoteBadges` for the split).
/// Draws only the stroke; its transparent centre shows the hole the text
/// surface punched — or, outside the surface's bounds, the page itself.
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
        // Indicator only: the whole highlight is the hit target, and VoiceOver
        // learns about the note from the annotation itself.
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
