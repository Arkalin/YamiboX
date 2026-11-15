import UIKit
import YamiboXCore

@MainActor
struct ReaderVerticalScrollStep {
    enum Outcome { case scrolled, atEdge, unavailable }

    private var pending: (y: CGFloat, time: CFTimeInterval)?

    mutating func reset() { pending = nil }

    mutating func perform(_ direction: ReaderControlScrollDirection, in view: UIScrollView?) -> Outcome {
        guard let view, view.bounds.height > 0 else { return .unavailable }
        let range = ReaderVerticalBoundaryAttempt.limits(view)
        let y = view.contentOffset.y
        let down = direction == .down
        if down ? y >= range.upperBound - 0.5 : y <= range.lowerBound + 0.5 { return .atEdge }

        // Rapid steps compound against the previous destination while its
        // animation is still catching up.
        let now = CACurrentMediaTime()
        let start = pending.flatMap { now - $0.time < 0.45 ? $0.y : nil } ?? y
        let step = view.bounds.height * CGFloat(ReaderControlCommandResolver.verticalScrollViewportFraction)
        let target = min(max(start + (down ? step : -step), range.lowerBound), range.upperBound)
        pending = (target, now)
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: !UIAccessibility.isReduceMotionEnabled)
        return .scrolled
    }
}
