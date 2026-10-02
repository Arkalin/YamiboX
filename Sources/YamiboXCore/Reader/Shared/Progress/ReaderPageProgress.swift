import Foundation

/// Page-based reading progress includes the page currently being displayed.
/// Keep the inverse mapping aligned with the displayed percentage, including
/// single-page content and the first page's nonzero position.
package enum ReaderPageProgress {
    package static func fraction(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(min(max(index, 0), count - 1) + 1) / Double(count)
    }

    package static func index(fraction: Double, count: Int) -> Int {
        guard count > 0, fraction.isFinite else { return 0 }
        let fraction = min(max(fraction, 0), 1)
        return min(max(Int((fraction * Double(count)).rounded()) - 1, 0), count - 1)
    }
}
