import Observation
import SwiftUI
import UIKit
import YamiboXCore

enum ReaderRemoteCursorStyle: Equatable { case arrow, text, focus }
enum ReaderRemoteKind: Equatable { case novelPaged, novelVertical, mangaPaged, mangaVertical
    var isVertical: Bool { self == .novelVertical || self == .mangaVertical }
    var isManga: Bool { self == .mangaPaged || self == .mangaVertical }
}

@MainActor
struct ReaderRemoteDrag {
    enum End { case completed, cancelled }
    let update: (CGPoint) -> Void
    let finish: (End) -> Void
}

@MainActor
struct ReaderRemoteTransform {
    let isCurrent: () -> Bool
    let update: (CGFloat, CGPoint) -> Void
    let pan: (CGPoint) -> Void
    let finish: () -> Void
}

@MainActor
@Observable
final class ReaderExternalInput {
    private(set) var location = CGPoint.zero
    private(set) var cursorStyle = ReaderRemoteCursorStyle.arrow
    private(set) var isVisible = false
    private(set) var isEnabled = false
    private(set) var kind = ReaderRemoteKind.novelPaged
    var gestureRegionLayout: ReaderGestureRegionLayout = .classic
    private(set) var textMenu: NovelTextMenu?
    @ObservationIgnored private var bounds = CGRect.zero
    @ObservationIgnored var sensitivity = CGFloat(ExternalDisplaySettings.defaultTrackpadSensitivity)
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var touching = false
    private(set) var epoch = UUID()
    @ObservationIgnored let targets = ReaderRemoteTargetRegistry()
    @ObservationIgnored weak var buttonViewport: ReaderViewportLifetime?
    @ObservationIgnored weak var scrollRelay: ReaderExternalScrollRelay?
    @ObservationIgnored private var activeContent: AnyHashable?
    @ObservationIgnored private var activeDrag: ReaderRemoteDrag?
    @ObservationIgnored private var activeTransform: ReaderRemoteTransform?
    @ObservationIgnored private weak var activeTarget: ReaderRemoteTargetProbe?
    @ObservationIgnored private var activeRevision: UUID?
    @ObservationIgnored private var pairScale: CGFloat = 1
    @ObservationIgnored private var pairTranslation = CGPoint.zero

    deinit { idleTask?.cancel() }

    func configure(_ kind: ReaderRemoteKind, content: AnyHashable) {
        guard self.kind != kind || activeContent != content else { return }
        cancel()
        self.kind = kind
        activeContent = content
        textMenu = nil
    }

    func updateTextMenu(_ menu: NovelTextMenu?) {
        if textMenu?.id != menu?.id { textMenu = menu }
    }

    func updateBounds(_ bounds: CGRect) {
        let first = self.bounds.isEmpty
        if !first, self.bounds != bounds { cancel() }
        self.bounds = bounds
        location = first ? CGPoint(x: bounds.midX, y: bounds.midY) : clamped(location)
    }

    func setEnabled(_ enabled: Bool, revealCursor: Bool = true) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        cancel()
        if enabled && revealCursor { show() }
    }

    func reset() {
        cancel()
        buttonViewport = nil
        targets.reset()
        bounds = .zero
        activeContent = nil
        textMenu = nil
    }

    @discardableResult
    func step(_ direction: ReaderControlScrollDirection) -> Bool {
        guard isEnabled, let buttonViewport else { return false }
        cancel()
        return buttonViewport.performExternalPageStep(direction)
    }

    func interruptMotion() {
        if touching || scrollRelay?.isMoving == true { cancel() }
    }

    func begin() -> UUID {
        if isEnabled {
            scrollRelay?.interrupt()
            touching = true
            show()
        }
        return epoch
    }

    func admits(_ epoch: UUID) -> Bool { isEnabled && self.epoch == epoch }

    func scrollTarget() -> ReaderRemoteScrollTarget? {
        guard isEnabled, kind.isVertical,
              let target = targets.contentTarget(where: { $0.verticalScroll != nil }),
              var scroll = target.actions.verticalScroll?(), scroll.isAttached() else { return nil }
        let revision = target.revision
        scroll.admitsInput = { [weak self, weak target] in
            guard let self, let target else { return false }
            return target.revision == revision && target.actions.verticalScroll != nil &&
                self.targets.eligible(target)
        }
        return scroll
    }

    func beginScroll() -> UUID {
        epoch = UUID()
        finishManipulation(completed: false)
        touching = false
        hideCursor()
        return epoch
    }

    func hideCursor() {
        idleTask?.cancel()
        idleTask = nil
        isVisible = false
    }

    private func capture(_ target: ReaderRemoteTargetProbe) {
        activeTarget = target
        activeRevision = target.revision
    }

    private var targetIsCurrent: Bool {
        guard let activeTarget, activeTarget.revision == activeRevision else { return false }
        return !activeTarget.actions.blocksTap && targets.eligible(activeTarget) &&
            activeTransform?.isCurrent() != false
    }

    func move(_ delta: CGPoint, epoch: UUID) {
        guard admits(epoch) else { return }
        if activeDrag != nil || activeTransform != nil, !targetIsCurrent {
            cancel()
            return
        }
        if let activeTransform {
            activeTransform.pan(scaledPan(delta))
            return
        }
        let gain = 1.6 * sensitivity
        location = clamped(CGPoint(x: location.x + delta.x * gain, y: location.y + delta.y * gain))
        activeDrag?.update(location)
        refreshCursorStyle()
    }

    func end(epoch: UUID) {
        guard admits(epoch) else { return }
        finishManipulation(completed: targetIsCurrent)
        let shouldShowCursor = isVisible || (kind.isManga && touching)
        touching = false
        if shouldShowCursor { show() }
    }

    func cancelGesture(epoch: UUID) {
        if admits(epoch) { cancel() }
    }

    func click(epoch: UUID, double: Bool) {
        guard admits(epoch), let target = clickTarget else { return }
        if double { target.actions.doubleTap?(location) }
        else { target.actions.tap?(location) }
        refreshCursorStyle()
    }

    var canDoubleClick: Bool { clickTarget?.actions.doubleTap != nil }

    private var clickTarget: ReaderRemoteTargetProbe? {
        targets.target(at: location) { $0.tap != nil || $0.doubleTap != nil || $0.blocksTap }
    }

    func hold(epoch: UUID) -> Bool {
        guard admits(epoch),
              let target = targets.target(at: location, where: { $0.tap != nil || $0.hold != nil || $0.blocksTap }),
              let hold = target.actions.hold else { return false }
        let result = hold(location)
        guard admits(epoch) else { return result.handled }
        if let drag = result.drag {
            capture(target)
            activeDrag = drag
        }
        return result.handled
    }

    func beginSingleDrag(epoch: UUID) {
        guard admits(epoch), activeDrag == nil, activeTransform == nil,
              let target = targets.target(at: location, where: { $0.drag != nil || $0.transform != nil || $0.tap != nil || $0.blocksTap }) else { return }
        if let drag = target.actions.drag?(location) {
            capture(target)
            activeDrag = drag
        } else if let transform = target.actions.transform?(location, false) {
            capture(target)
            activeTransform = transform
            hideCursor()
        }
    }

    func beginTwoFinger(epoch: UUID) {
        guard admits(epoch) else { return }
        finishManipulation(completed: false)
        guard let target = targets.target(at: location, where: { $0.transform != nil || $0.tap != nil || $0.blocksTap }),
              let transform = target.actions.transform?(location, true) else { return }
        capture(target)
        activeTransform = transform
        pairScale = 1
        pairTranslation = .zero
        hideCursor()
    }

    func updateTwoFinger(translation: CGPoint, ratio: CGFloat, epoch: UUID) {
        guard admits(epoch), let activeTransform else { return }
        guard targetIsCurrent else { cancel(); return }
        pairScale *= ratio
        let pan = scaledPan(translation)
        pairTranslation.x += pan.x
        pairTranslation.y += pan.y
        activeTransform.update(pairScale, pairTranslation)
    }

    private func scaledPan(_ delta: CGPoint) -> CGPoint {
        CGPoint(x: delta.x * sensitivity, y: delta.y * sensitivity)
    }

    private func finishManipulation(completed: Bool) {
        let drag = activeDrag
        let transform = activeTransform
        activeDrag = nil
        activeTransform = nil
        activeTarget = nil
        activeRevision = nil
        drag?.finish(completed ? .completed : .cancelled)
        transform?.finish()
    }

    private func refreshCursorStyle() {
        cursorStyle = kind.isManga ? .focus :
            (targets.target(at: location, where: { $0.textHit != nil || $0.tap != nil || $0.blocksTap })?.actions.textHit?(location) == true ? .text : .arrow)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(bounds.minX, point.x), max(bounds.minX, bounds.maxX - 1)),
                y: min(max(bounds.minY, point.y), max(bounds.minY, bounds.maxY - 1)))
    }

    private func show() {
        if kind.isManga,
           targets.contentTarget(where: { $0.mangaIsZoomed != nil })?.actions.mangaIsZoomed?() == true {
            hideCursor()
            return
        }
        refreshCursorStyle()
        isVisible = true
        idleTask?.cancel()
        guard !touching else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(.easeOut(duration: 0.18)) { self?.isVisible = false }
        }
    }

    private func cancel() {
        epoch = UUID()
        finishManipulation(completed: false)
        scrollRelay?.interrupt()
        touching = false
        hideCursor()
    }
}

struct ReaderExternalCursor: View {
    let input: ReaderExternalInput

    var body: some View {
        if input.isVisible {
            let style = input.cursorStyle
            Canvas { context, _ in
                let pointer = Path { path in
                    switch style {
                    case .focus:
                        path.addEllipse(in: CGRect(x: 6, y: 7, width: 10, height: 10))
                    case .text:
                        path.move(to: CGPoint(x: 11, y: 4))
                        path.addLine(to: CGPoint(x: 11, y: 20))
                        path.move(to: CGPoint(x: 7, y: 4))
                        path.addLine(to: CGPoint(x: 15, y: 4))
                        path.move(to: CGPoint(x: 7, y: 20))
                        path.addLine(to: CGPoint(x: 15, y: 20))
                    case .arrow:
                        path.move(to: .zero)
                        path.addLines([CGPoint(x: 18, y: 13), CGPoint(x: 10, y: 14),
                                       CGPoint(x: 7, y: 21), .zero])
                        path.closeSubpath()
                    }
                }
                if style == .arrow {
                    context.fill(pointer, with: .color(.white))
                    context.stroke(pointer, with: .color(.black), lineWidth: 1.5)
                } else {
                    context.stroke(pointer, with: .color(.black), lineWidth: 3)
                    context.stroke(pointer, with: .color(.white), lineWidth: 1.4)
                }
            }
            .frame(width: 22, height: 24)
            .position(x: input.location.x + (style == .arrow ? 11 : 0),
                      y: input.location.y + (style == .arrow ? 12 : 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct ReaderDeviceTrackpad: View {
    let input: ReaderExternalInput
    let showsControls: Bool
    let onMenu: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height / 2
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    if input.textMenu == nil {
                        ReaderDeviceControlLabel(title: L10n.string("reader.external.trackpad"))
                    }
                    TouchArea(input: input)
                        .id(input.epoch)
                        .accessibilityHidden(true)
                    if let menu = input.textMenu {
                        ReaderDeviceTextMenu(menu: menu)
                            .id(menu.id)
                    }
                }
                .frame(height: height)

                Group {
                    if input.kind.isVertical {
                        ReaderExternalScrollArea(input: input, onMenu: onMenu)
                    } else {
                        ReaderGestureRegionMap(layout: input.gestureRegionLayout) { action, index, shape in
                            regionButton(action, index: index, shape: shape)
                        }
                        .id(input.gestureRegionLayout)
                    }
                }
                .frame(height: height)
                .overlay(alignment: .top) { separator.frame(height: 1) }
            }
            .disabled(!input.isEnabled)
            .readerChromeFadeVisibility(showsControls, hiddenOpacity: 0.25)
        }
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.08).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func regionButton(_ action: ReaderGestureRegionAction, index: Int, shape: ReaderGestureRegionShape) -> some View {
        let shade: Double = switch action {
        case .previous: 0.08
        case .toggleChrome: 0.19
        case .next: 0.13
        }
        let id: String = switch action {
        case .previous: "previous"
        case .toggleChrome: "menu"
        case .next: input.gestureRegionLayout == .bothSidesAdvance && index == 0 ? "next-left" : "next"
        }
        return Button {
            switch action {
            case .previous: input.step(.up)
            case .toggleChrome: onMenu()
            case .next: input.step(.down)
            }
        } label: {
            GeometryReader { proxy in
                let frame = shape.labelFrame(in: CGRect(origin: .zero, size: proxy.size))
                ReaderDeviceControlLabel(title: action.title)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            .background { shape.fill(Color(white: shade)) }
            .contentShape(.interaction, shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityActivationPoint(shape.labelCenter)
        .accessibilityIdentifier("reader-external-\(id)")
    }

    private var separator: some View {
        Color.white.opacity(0.18).allowsHitTesting(false).accessibilityHidden(true)
    }

    private struct TouchArea: UIViewRepresentable {
        let input: ReaderExternalInput
        func makeUIView(context: Context) -> Pad { Pad(input: input) }
        func updateUIView(_ pad: Pad, context: Context) {}
    }

    private final class Pad: UIView, UIGestureRecognizerDelegate {
        private let input: ReaderExternalInput
        private var last = CGPoint.zero
        private var origin = CGPoint.zero
        private var moved = false
        private var epoch: UUID?
        private var points: [UITouch] = []
        private var lastPair: (center: CGPoint, distance: CGFloat)?
        private var usedMultipleFingers = false
        private var blocked = false
        private var held = false
        private lazy var doubleTap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            recognizer.numberOfTapsRequired = 2
            recognizer.delegate = self
            return recognizer
        }()

        init(input: ReaderExternalInput) {
            self.input = input
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            hold.minimumPressDuration = 0.55
            hold.allowableMovement = 6
            tap.require(toFail: doubleTap)
            tap.require(toFail: hold)
            doubleTap.require(toFail: hold)
            for recognizer in [tap, doubleTap, hold] {
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesEnded = false
                addGestureRecognizer(recognizer)
            }
        }

        required init?(coder: NSCoder) { nil }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            input.canDoubleClick
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let epoch, !blocked, !usedMultipleFingers, !moved, !held else { return }
            input.click(epoch: epoch, double: recognizer === doubleTap)
        }

        @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let epoch, !blocked, !usedMultipleFingers, !moved else { return }
            held = input.hold(epoch: epoch)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if points.isEmpty, let first = touches.first {
                last = first.location(in: self)
                origin = last
                moved = false
                usedMultipleFingers = false
                held = false
                blocked = false
                epoch = input.begin()
            }
            points.append(contentsOf: touches)
            guard let epoch else { return }
            if points.count == 2, !blocked {
                usedMultipleFingers = true
                lastPair = samplePair()
                input.beginTwoFinger(epoch: epoch)
            } else if points.count > 2 {
                blocked = true
                lastPair = nil
                input.cancelGesture(epoch: epoch)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let epoch, !blocked else { return }
            if let previous = lastPair, let current = samplePair() {
                lastPair = current
                input.updateTwoFinger(
                    translation: CGPoint(x: current.center.x - previous.center.x, y: current.center.y - previous.center.y),
                    ratio: current.distance / previous.distance, epoch: epoch
                )
                return
            }
            guard points.count == 1, let finger = points.first, touches.contains(finger) else { return }
            if usedMultipleFingers, !input.kind.isManga { return }
            let point = finger.location(in: self)
            if !moved, hypot(point.x - origin.x, point.y - origin.y) > 6 {
                moved = true
                if !held, !usedMultipleFingers { input.beginSingleDrag(epoch: epoch) }
            }
            // Preserve the original focus until tap, hold or drag is resolved.
            if moved || held || usedMultipleFingers {
                input.move(CGPoint(x: point.x - last.x, y: point.y - last.y), epoch: epoch)
                last = point
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, permitsClick: true) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, permitsClick: false) }

        private func finish(_ touches: Set<UITouch>, permitsClick: Bool) {
            guard points.contains(where: touches.contains), let epoch else { return }
            points.removeAll { touches.contains($0) }
            if !permitsClick {
                blocked = true
                input.cancelGesture(epoch: epoch)
            }
            if lastPair != nil, points.count != 2 {
                lastPair = nil
                if let remaining = points.first { last = remaining.location(in: self); origin = last }
            }
            guard points.isEmpty else { return }
            if permitsClick, !blocked { input.end(epoch: epoch) }
        }

        private func samplePair() -> (center: CGPoint, distance: CGFloat)? {
            guard points.count == 2 else { return nil }
            let a = points[0].location(in: self), b = points[1].location(in: self)
            return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), max(1, hypot(a.x - b.x, a.y - b.y)))
        }
    }
}

struct ReaderDeviceControlButton: View {
    let title: String
    let id: String
    let action: () -> Void

    static func menu(action: @escaping () -> Void) -> Self {
        Self(title: L10n.string("reader.external.menu"), id: "menu", action: action)
    }

    var body: some View {
        Button(action: action) {
            ReaderDeviceControlLabel(title: title)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader-external-\(id)")
    }
}

private struct ReaderDeviceControlLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Color(white: 0.72))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReaderDeviceInteractionBackdrop: View {
    var body: some View {
        Color(white: 0.08)
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
    }
}
