import SwiftUI

/// Accumulates a physical horizontal gesture and commits once on lift.
/// Continuous scroll and zoom use UIKit directly, not discrete paging commands.
@MainActor
final class ReaderRemotePageTurn {
    private var translation = CGPoint.zero

    func add(_ delta: CGPoint) {
        translation.x += delta.x
        translation.y += delta.y
    }

    func finish(cancelled: Bool, rightToLeft: Bool, width: CGFloat, turn: (Int) -> Void) {
        let movement = translation
        translation = .zero
        guard !cancelled, abs(movement.x) > abs(movement.y) * 1.35,
              abs(movement.x) >= min(max(width * 0.055, 40), 85) else { return }
        turn((movement.x > 0) == rightToLeft ? 1 : -1)
    }

    func cancel() { translation = .zero }
}
