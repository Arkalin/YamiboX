import Observation
import SwiftUI
import UIKit
import YamiboXCore

@MainActor
@Observable
final class ReaderExternalInput {
    private enum GestureKind { case pending, drag, scroll, pinch }
    private struct Gesture {
        weak var dragTarget: ReaderRemoteTargetProbe?
        weak var contentTarget: ReaderRemoteTargetProbe?
        var dragRevision: UUID?
        var contentRevision: UUID?
        var kind = GestureKind.pending
        var translation = CGPoint.zero
        var magnification: CGFloat = 1
        var layer: ReaderRemoteLayer
        var finish: ((Bool) -> Void)?
    }
    private(set) var location = CGPoint.zero
    private(set) var isVisible = false
    @ObservationIgnored private var bounds = CGRect.zero
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var touching = false
    @ObservationIgnored private(set) var epoch = UUID()
    @ObservationIgnored let targets = ReaderRemoteTargetRegistry()
    @ObservationIgnored private var gesture: Gesture?
    var menu: AnyView?

    deinit { idleTask?.cancel() }

    func updateBounds(_ bounds: CGRect) {
        let first = self.bounds.isEmpty
        self.bounds = bounds
        location = first ? CGPoint(x: bounds.midX, y: bounds.midY) : clamped(location)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        cancel()
        if enabled { show() }
    }

    func reset() {
        cancel()
        menu = nil
        targets.reset()
        bounds = .zero
    }

    func presentMenu(@ViewBuilder _ items: () -> some View) {
        menu = AnyView(
            VStack(alignment: .leading, spacing: 10) { items() }
                .buttonStyle(.bordered)
                .padding(20)
        )
    }

    func begin() -> UUID {
        if isEnabled {
            touching = true
            show()
        }
        return epoch
    }

    func admits(_ epoch: UUID) -> Bool { isEnabled && self.epoch == epoch }

    func move(_ delta: CGPoint, epoch: UUID) {
        guard admits(epoch) else { return }
        location = clamped(CGPoint(x: location.x + delta.x * 1.6, y: location.y + delta.y * 1.6))
    }

    func end(epoch: UUID) {
        guard admits(epoch) else { return }
        touching = false
        show()
    }

    func click(epoch: UUID) {
        guard admits(epoch),
              let target = targets.target(at: location, where: { $0.tap != nil || $0.blocksTap }),
              let frame = target.visibleFrame else { return }
        if target.remoteLayer.depth == 100 && target.actions.tap != nil { menu = nil }
        target.actions.tap?(location, frame)
    }

    func hold(epoch: UUID) -> Bool {
        guard admits(epoch),
              let target = targets.target(at: location, where: { $0.tap != nil || $0.hold != nil || $0.blocksTap }),
              let hold = target.actions.hold else { return false }
        hold(location)
        return true
    }

    func beginTwoFinger(epoch: UUID) {
        guard admits(epoch) else { return }
        let drag = targets.target(at: location, where: { $0.drag != nil })
        let content = targets.target(at: location, where: { $0.scroll != nil || $0.pinch != nil })
        gesture = Gesture(
            dragTarget: drag, contentTarget: content,
            dragRevision: drag?.revision, contentRevision: content?.revision,
            layer: targets.activeLayer
        )
    }

    func updateTwoFinger(translation: CGPoint, ratio: CGFloat, epoch: UUID) {
        guard admits(epoch) else { return }
        guard var gesture, gesture.layer == targets.activeLayer else {
            finishTwoFinger(cancelled: true)
            return
        }
        var delta = translation
        var scale = ratio
        let wasPending = gesture.kind == .pending
        gesture.translation.x += translation.x
        gesture.translation.y += translation.y
        if wasPending {
            gesture.magnification *= ratio
            let moved = hypot(gesture.translation.x, gesture.translation.y)
            let pinched = abs(log(max(gesture.magnification, 0.001)))
            if gesture.dragTarget != nil, moved >= 8 {
                gesture.kind = .drag
            } else if pinched >= 0.075, gesture.dragTarget == nil,
                      gesture.layer == .body || gesture.contentTarget?.actions.pinch != nil {
                gesture.kind = .pinch
            } else if moved >= 10 {
                gesture.kind = .scroll
            }
            delta = gesture.translation
            scale = gesture.magnification
        }
        switch gesture.kind {
        case .pending:
            self.gesture = gesture
        case .drag:
            guard let target = gesture.dragTarget, target.revision == gesture.dragRevision,
                  targets.eligible(target), let frame = target.visibleFrame, let drag = target.actions.drag else {
                finishTwoFinger(cancelled: true)
                return
            }
            if wasPending { gesture.finish = target.actions.finishDrag }
            self.gesture = gesture
            if wasPending { target.actions.didBeginDrag?() }
            drag(gesture.translation, frame)
        case .scroll, .pinch:
            guard let target = gesture.contentTarget, target.revision == gesture.contentRevision,
                  targets.eligible(target), target.visibleFrame != nil else {
                finishTwoFinger(cancelled: true)
                return
            }
            if gesture.kind == .scroll {
                if wasPending { gesture.finish = target.actions.finishScroll }
                self.gesture = gesture
                if wasPending { target.actions.didBeginScroll?() }
                target.actions.scroll?(delta)
            } else {
                self.gesture = gesture
                target.actions.pinch?(scale, location)
            }
        }
    }

    func finishTwoFinger(cancelled: Bool, from epoch: UUID? = nil) {
        if let epoch, !admits(epoch) { return }
        guard let gesture else { return }
        self.gesture = nil
        let isDrag = gesture.kind == .drag
        let target = isDrag ? gesture.dragTarget : gesture.contentTarget
        let revision = isDrag ? gesture.dragRevision : gesture.contentRevision
        let valid = target.map {
            $0.revision == revision && targets.eligible($0) && $0.visibleFrame != nil &&
                (isDrag ? $0.actions.drag != nil : $0.actions.scroll != nil)
        } ?? false
        // Tear down the originally captured action even if its probe was
        // removed or reused; a replacement target must never commit the drag.
        gesture.finish?(cancelled || !valid)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(bounds.minX, point.x), max(bounds.minX, bounds.maxX - 1)),
                y: min(max(bounds.minY, point.y), max(bounds.minY, bounds.maxY - 1)))
    }

    private func show() {
        isVisible = true
        idleTask?.cancel()
        guard !touching else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.isVisible = false
        }
    }

    private func cancel() {
        finishTwoFinger(cancelled: true)
        epoch = UUID()
        touching = false
        idleTask?.cancel()
        idleTask = nil
        isVisible = false
    }
}

struct ReaderExternalCursor: View {
    let input: ReaderExternalInput

    var body: some View {
        if input.isVisible {
            Canvas { context, _ in
                let pointer = Path { path in
                    path.move(to: .zero)
                    path.addLines([CGPoint(x: 18, y: 13), CGPoint(x: 10, y: 14),
                                   CGPoint(x: 7, y: 21), .zero])
                    path.closeSubpath()
                }
                context.fill(pointer, with: .color(.white))
                context.stroke(pointer, with: .color(.black), lineWidth: 1.5)
            }
            .frame(width: 22, height: 24)
            .position(x: input.location.x + 10, y: input.location.y + 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct ReaderDeviceTrackpad: View {
    let input: ReaderExternalInput

    var body: some View {
        ZStack {
            Color(white: 0.08)
            Text(L10n.string("reader.external.trackpad"))
                .foregroundStyle(Color(white: 0.72))
                .multilineTextAlignment(.center)
                .padding(20)
            TouchArea(input: input)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private struct TouchArea: UIViewRepresentable {
        let input: ReaderExternalInput
        func makeUIView(context: Context) -> Pad { Pad(input: input) }
        func updateUIView(_ pad: Pad, context: Context) {}
    }

    private final class Pad: UIView {
        private let input: ReaderExternalInput
        private var active: UITouch?
        private var last = CGPoint.zero
        private var origin = CGPoint.zero
        private var moved = false
        private var downAt: TimeInterval = 0
        private var epoch: UUID?
        private var points: [UITouch] = []
        private var lastPair: (center: CGPoint, distance: CGFloat)?
        private var usedMultipleFingers = false
        private var holdTask: Task<Void, Never>?
        private var held = false

        isolated deinit { holdTask?.cancel() }

        init(input: ReaderExternalInput) {
            self.input = input
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
        }

        required init?(coder: NSCoder) { nil }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if points.isEmpty, let first = touches.first {
                active = first
                last = first.location(in: self)
                origin = last
                moved = false
                usedMultipleFingers = false
                held = false
                downAt = first.timestamp
                epoch = input.begin()
                if let epoch {
                    holdTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                        guard let self, !usedMultipleFingers, !moved else { return }
                        held = input.hold(epoch: epoch)
                    }
                }
            }
            points.append(contentsOf: touches)
            if points.count == 2, !usedMultipleFingers, let epoch {
                holdTask?.cancel()
                usedMultipleFingers = true
                lastPair = samplePair()
                input.beginTwoFinger(epoch: epoch)
            } else if points.count > 2 {
                holdTask?.cancel()
                usedMultipleFingers = true
                lastPair = nil
                input.finishTwoFinger(cancelled: true, from: epoch)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let epoch else { return }
            if let previous = lastPair, let current = samplePair() {
                lastPair = current
                input.updateTwoFinger(
                    translation: CGPoint(x: current.center.x - previous.center.x, y: current.center.y - previous.center.y),
                    ratio: current.distance / max(previous.distance, 1), epoch: epoch
                )
                return
            }
            guard !usedMultipleFingers, let active, touches.contains(active) else { return }
            let point = active.location(in: self)
            if hypot(point.x - origin.x, point.y - origin.y) > 6 { moved = true }
            input.move(CGPoint(x: point.x - last.x, y: point.y - last.y), epoch: epoch)
            last = point
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, permitsClick: true) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, permitsClick: false) }

        private func finish(_ touches: Set<UITouch>, permitsClick: Bool) {
            points.removeAll { touches.contains($0) }
            if lastPair != nil, points.count != 2 {
                lastPair = nil
                if let epoch { input.finishTwoFinger(cancelled: !permitsClick, from: epoch) }
            }
            guard points.isEmpty, let epoch else { return }
            holdTask?.cancel()
            self.epoch = nil
            if permitsClick, !held, !usedMultipleFingers, !moved, let active, active.timestamp - downAt < 0.32 {
                input.click(epoch: epoch)
            }
            active = nil
            input.end(epoch: epoch)
        }

        private func samplePair() -> (center: CGPoint, distance: CGFloat)? {
            guard points.count == 2 else { return nil }
            let a = points[0].location(in: self), b = points[1].location(in: self)
            return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), max(1, hypot(a.x - b.x, a.y - b.y)))
        }
    }
}

struct ReaderDeviceInteractionBackdrop: View {
    var body: some View {
        Color(white: 0.08)
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
    }
}
